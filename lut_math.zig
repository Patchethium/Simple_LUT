const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Rgb = extern struct {
    r: f32,
    g: f32,
    b: f32,

    pub const zero = Rgb{ .r = 0, .g = 0, .b = 0 };
    pub const one = Rgb{ .r = 1, .g = 1, .b = 1 };
};

/// Values match the plugin UI and the Lua `Type` track.
pub const Mode = enum(u8) {
    nearest = 1,
    tetrahedral = 2,
    trilinear = 3,

    pub fn fromInt(value: anytype) ?Mode {
        return switch (value) {
            1 => .nearest,
            2 => .tetrahedral,
            3 => .trilinear,
            else => null,
        };
    }
};

pub const min_size = 2;
/// 129³ lattice points are ~25 MB, which still fits AviUtl's 32-bit address space.
pub const max_size = 129;
pub const max_file_bytes = 64 * 1024 * 1024;

pub const Lut = struct {
    size: usize,
    /// Indexed by `index(r, g, b)`, blue varying fastest.
    values: []Rgb,
    /// Input range of the lattice; inputs are remapped from this range onto [0, size - 1].
    domain_min: Rgb = Rgb.zero,
    domain_max: Rgb = Rgb.one,

    pub fn init(allocator: Allocator, size: usize) Allocator.Error!Lut {
        return .{ .size = size, .values = try allocator.alloc(Rgb, size * size * size) };
    }

    pub fn deinit(self: *Lut, allocator: Allocator) void {
        allocator.free(self.values);
        self.* = undefined;
    }

    pub fn index(self: *const Lut, r: usize, g: usize, b: usize) usize {
        return (r * self.size + g) * self.size + b;
    }

    pub fn at(self: *const Lut, r: usize, g: usize, b: usize) Rgb {
        return self.values[self.index(r, g, b)];
    }
};

pub const Format = enum { cube, @"3dl", m3d };

pub const ParseError = error{
    MissingSize,
    InvalidSize,
    InvalidDomain,
    BadData,
    IncompleteData,
    TooMuchData,
    UnsupportedFormat,
} || Allocator.Error;

/// Accepts `u8` or `u16` (UTF-16) paths; only the ASCII extension is inspected.
pub fn formatFromPath(comptime Char: type, path: []const Char) ?Format {
    if (endsWithExtension(Char, path, ".cube")) return .cube;
    if (endsWithExtension(Char, path, ".3dl")) return .@"3dl";
    if (endsWithExtension(Char, path, ".m3d")) return .m3d;
    return null;
}

fn endsWithExtension(comptime Char: type, path: []const Char, extension: []const u8) bool {
    if (path.len < extension.len) return false;
    for (path[path.len - extension.len ..], extension) |char, expected| {
        if (char > 0x7f or std.ascii.toLower(@intCast(char)) != expected) return false;
    }
    return true;
}

pub fn parse(allocator: Allocator, bytes: []const u8, format: Format) ParseError!Lut {
    return switch (format) {
        .cube => parseCube(allocator, bytes),
        .@"3dl" => parse3dl(allocator, bytes),
        .m3d => parseM3d(allocator, bytes),
    };
}

/// Reads and parses a LUT through `std.Io`. The Windows plugins read through wide-path
/// APIs instead and call `parse` directly.
pub fn loadFile(io: std.Io, allocator: Allocator, path: []const u8) !Lut {
    const format = formatFromPath(u8, path) orelse return error.UnsupportedFormat;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_bytes));
    defer allocator.free(bytes);
    return parse(allocator, bytes, format);
}

fn parseCube(allocator: Allocator, bytes: []const u8) ParseError!Lut {
    var lut: ?Lut = null;
    errdefer if (lut) |*table| table.deinit(allocator);
    var domain_min = Rgb.zero;
    var domain_max = Rgb.one;
    var count: usize = 0;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
        const first = tokens.next() orelse continue;
        if (first[0] == '#') continue;
        if (isNumber(first)) {
            const table = if (lut) |*table| table else return error.MissingSize;
            if (count >= table.values.len) return error.TooMuchData;
            const rgb = try parseRgb(first, &tokens);
            if (tokens.next() != null) return error.BadData;
            // .cube records advance red first.
            const size = table.size;
            table.values[table.index(count % size, count / size % size, count / (size * size))] = rgb;
            count += 1;
        } else if (std.mem.eql(u8, first, "LUT_3D_SIZE")) {
            if (lut != null) return error.InvalidSize;
            lut = try Lut.init(allocator, try parseSize(tokens.next()));
        } else if (std.mem.eql(u8, first, "DOMAIN_MIN")) {
            domain_min = try parseRgb(tokens.next() orelse return error.BadData, &tokens);
        } else if (std.mem.eql(u8, first, "DOMAIN_MAX")) {
            domain_max = try parseRgb(tokens.next() orelse return error.BadData, &tokens);
        } else if (std.mem.eql(u8, first, "LUT_3D_INPUT_RANGE")) {
            // Resolve's single-range spelling of DOMAIN_MIN/DOMAIN_MAX.
            const low = try parseFloat(tokens.next());
            const high = try parseFloat(tokens.next());
            domain_min = .{ .r = low, .g = low, .b = low };
            domain_max = .{ .r = high, .g = high, .b = high };
        } else if (std.mem.eql(u8, first, "LUT_1D_SIZE")) {
            return error.UnsupportedFormat;
        }
        // Other keywords (TITLE, LUT_1D_INPUT_RANGE, vendor extensions) carry no lattice data.
    }

    var table = lut orelse return error.MissingSize;
    if (count != table.values.len) return error.IncompleteData;
    if (!(domain_max.r > domain_min.r and domain_max.g > domain_min.g and domain_max.b > domain_min.b)) return error.InvalidDomain;
    table.domain_min = domain_min;
    table.domain_max = domain_max;
    return table;
}

fn parse3dl(allocator: Allocator, bytes: []const u8) ParseError!Lut {
    var entries: std.ArrayList([3]u32) = .empty;
    defer entries.deinit(allocator);
    var shaper_size: ?usize = null;
    var mesh_size: ?usize = null;
    var output_bits: ?u5 = null;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
        const first = tokens.next() orelse continue;
        if (first[0] == '#') continue;
        if (!isInteger(first)) {
            // Autodesk header: "Mesh <input bits> <output bits>".
            if (std.ascii.eqlIgnoreCase(first, "Mesh")) {
                const input_bits = std.fmt.parseInt(u5, tokens.next() orelse return error.BadData, 10) catch return error.BadData;
                if (input_bits > 7) return error.InvalidSize;
                mesh_size = (@as(usize, 1) << input_bits) + 1;
                output_bits = std.fmt.parseInt(u5, tokens.next() orelse return error.BadData, 10) catch return error.BadData;
            }
            continue;
        }

        var values: [3]u32 = undefined;
        var columns: usize = 0;
        var token: ?[]const u8 = first;
        while (token) |text| : (token = tokens.next()) {
            const value = std.fmt.parseInt(u32, text, 10) catch return error.BadData;
            if (columns < 3) values[columns] = value;
            columns += 1;
        }
        if (columns > 3) {
            // The shaper/mesh line lists the input positions of each lattice point.
            if (shaper_size != null or entries.items.len != 0) return error.BadData;
            shaper_size = columns;
            continue;
        }
        if (columns != 3) return error.BadData;
        try entries.append(allocator, values);
    }

    const size = shaper_size orelse mesh_size orelse cubeRoot(entries.items.len) orelse return error.IncompleteData;
    if (size < min_size or size > max_size) return error.InvalidSize;
    if (entries.items.len < size * size * size) return error.IncompleteData;
    if (entries.items.len > size * size * size) return error.TooMuchData;

    const bits = output_bits orelse inferBits(entries.items);
    if (bits < 8 or bits > 16) return error.BadData;
    const scale = 1.0 / @as(f32, @floatFromInt((@as(u32, 1) << bits) - 1));
    const lut = try Lut.init(allocator, size);
    // .3dl records advance blue first, which matches the flat storage order.
    for (entries.items, lut.values) |entry, *value| value.* = .{
        .r = @as(f32, @floatFromInt(entry[0])) * scale,
        .g = @as(f32, @floatFromInt(entry[1])) * scale,
        .b = @as(f32, @floatFromInt(entry[2])) * scale,
    };
    return lut;
}

fn inferBits(entries: []const [3]u32) u5 {
    var largest: u32 = 0;
    for (entries) |entry| largest = @max(largest, entry[0], entry[1], entry[2]);
    if (largest <= 1023) return 10;
    if (largest <= 4095) return 12;
    return 16;
}

fn parseM3d(allocator: Allocator, bytes: []const u8) ParseError!Lut {
    var input_count: ?usize = null;
    var output_count: ?usize = null;
    // column[channel] is the data column holding that channel.
    var column = [3]usize{ 0, 1, 2 };
    var lut: ?Lut = null;
    errdefer if (lut) |*table| table.deinit(allocator);
    var count: usize = 0;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
        const first = tokens.next() orelse continue;
        if (first[0] == '#') continue;
        if (std.mem.eql(u8, first, "in")) {
            input_count = std.fmt.parseInt(usize, tokens.next() orelse return error.BadData, 0) catch return error.BadData;
        } else if (std.mem.eql(u8, first, "out")) {
            output_count = std.fmt.parseInt(usize, tokens.next() orelse return error.BadData, 0) catch return error.BadData;
        } else if (std.mem.eql(u8, first, "values")) {
            var seen = [3]bool{ false, false, false };
            for (0..3) |position| {
                const name = tokens.next() orelse return error.BadData;
                const channel: usize = switch (name[0]) {
                    'r' => 0,
                    'g' => 1,
                    'b' => 2,
                    else => return error.BadData,
                };
                if (seen[channel]) return error.BadData;
                seen[channel] = true;
                column[channel] = position;
            }
        } else if (isNumber(first)) {
            if (lut == null) {
                const inputs = input_count orelse return error.MissingSize;
                const size = cubeRoot(inputs) orelse return error.InvalidSize;
                if (size < min_size or size > max_size) return error.InvalidSize;
                lut = try Lut.init(allocator, size);
            }
            const table = &lut.?;
            if (count >= table.values.len) return error.TooMuchData;
            const outputs = output_count orelse return error.MissingSize;
            if (outputs < 2) return error.InvalidSize;
            var values: [3]f32 = undefined;
            values[0] = try parseFloat(first);
            values[1] = try parseFloat(tokens.next());
            values[2] = try parseFloat(tokens.next());
            if (tokens.next() != null) return error.BadData;
            const scale = 1.0 / @as(f32, @floatFromInt(outputs - 1));
            table.values[count] = .{ .r = values[column[0]] * scale, .g = values[column[1]] * scale, .b = values[column[2]] * scale };
            count += 1;
        }
    }

    const table = lut orelse return error.MissingSize;
    if (count != table.values.len) return error.IncompleteData;
    return table;
}

fn cubeRoot(count: usize) ?usize {
    var size: usize = 1;
    while (size * size * size < count) : (size += 1) {}
    return if (size * size * size == count) size else null;
}

fn isNumber(token: []const u8) bool {
    return std.ascii.isDigit(token[0]) or token[0] == '-' or token[0] == '+' or token[0] == '.';
}

/// `.3dl` headers such as `3DMESH` start with a digit, so data lines must be all digits.
fn isInteger(token: []const u8) bool {
    for (token) |char| if (!std.ascii.isDigit(char)) return false;
    return true;
}

fn parseSize(token: ?[]const u8) ParseError!usize {
    const size = std.fmt.parseInt(usize, token orelse return error.InvalidSize, 10) catch return error.InvalidSize;
    if (size < min_size or size > max_size) return error.InvalidSize;
    return size;
}

fn parseFloat(token: ?[]const u8) ParseError!f32 {
    return std.fmt.parseFloat(f32, token orelse return error.BadData) catch error.BadData;
}

fn parseRgb(first: []const u8, tokens: anytype) ParseError!Rgb {
    return .{ .r = try parseFloat(first), .g = try parseFloat(tokens.next()), .b = try parseFloat(tokens.next()) };
}

/// Maps 8-bit input onto lattice coordinates. Built once per frame.
pub const Sampler = struct {
    values: []const Rgb,
    size: usize,
    scale: [3]f32,
    offset: [3]f32,
    limit: f32,

    pub fn init(lut: *const Lut) Sampler {
        const last: f32 = @floatFromInt(lut.size - 1);
        const low = [3]f32{ lut.domain_min.r, lut.domain_min.g, lut.domain_min.b };
        const high = [3]f32{ lut.domain_max.r, lut.domain_max.g, lut.domain_max.b };
        var sampler = Sampler{ .values = lut.values, .size = lut.size, .scale = undefined, .offset = undefined, .limit = last };
        // point = (x / 255 - low) / (high - low) * (size - 1)
        for (0..3) |channel| {
            const width = high[channel] - low[channel];
            sampler.scale[channel] = last / (255.0 * width);
            sampler.offset[channel] = -low[channel] * last / width;
        }
        return sampler;
    }

    /// `input` channels are 0..255.
    pub fn sample(self: *const Sampler, comptime mode: Mode, input: Rgb) Rgb {
        const point = Rgb{
            .r = std.math.clamp(input.r * self.scale[0] + self.offset[0], 0, self.limit),
            .g = std.math.clamp(input.g * self.scale[1] + self.offset[1], 0, self.limit),
            .b = std.math.clamp(input.b * self.scale[2] + self.offset[2], 0, self.limit),
        };
        return switch (mode) {
            .nearest => self.values[(nearest(point.r) * self.size + nearest(point.g)) * self.size + nearest(point.b)],
            .trilinear => trilinear(self, point),
            .tetrahedral => tetrahedral(self, point),
        };
    }
};

/// The lattice cell containing `point`: index of its low corner, the index steps to the next
/// point along each axis (zero on the last plane), and the fractional position inside the cell.
const Cell = struct {
    base: usize,
    step_r: usize,
    step_g: usize,
    step_b: usize,
    d: Rgb,

    fn init(sampler: *const Sampler, point: Rgb) Cell {
        const size = sampler.size;
        const r0 = previous(point.r);
        const g0 = previous(point.g);
        const b0 = previous(point.b);
        return .{
            .base = (r0 * size + g0) * size + b0,
            .step_r = (next(r0, size) - r0) * size * size,
            .step_g = (next(g0, size) - g0) * size,
            .step_b = next(b0, size) - b0,
            .d = .{ .r = point.r - @as(f32, @floatFromInt(r0)), .g = point.g - @as(f32, @floatFromInt(g0)), .b = point.b - @as(f32, @floatFromInt(b0)) },
        };
    }

    fn corner(self: Cell, values: []const Rgb, r: u1, g: u1, b: u1) Rgb {
        return values[self.base + r * self.step_r + g * self.step_g + b * self.step_b];
    }
};

fn trilinear(sampler: *const Sampler, point: Rgb) Rgb {
    const cell = Cell.init(sampler, point);
    const v = sampler.values;
    const d = cell.d;
    return mix(mix(mix(cell.corner(v, 0, 0, 0), cell.corner(v, 1, 0, 0), d.r), mix(cell.corner(v, 0, 1, 0), cell.corner(v, 1, 1, 0), d.r), d.g), mix(mix(cell.corner(v, 0, 0, 1), cell.corner(v, 1, 0, 1), d.r), mix(cell.corner(v, 0, 1, 1), cell.corner(v, 1, 1, 1), d.r), d.g), d.b);
}

fn tetrahedral(sampler: *const Sampler, point: Rgb) Rgb {
    const cell = Cell.init(sampler, point);
    const v = sampler.values;
    const d = cell.d;
    const c000 = cell.corner(v, 0, 0, 0);
    const c111 = cell.corner(v, 1, 1, 1);
    if (d.r > d.g) {
        if (d.g > d.b) return weighted(c000, cell.corner(v, 1, 0, 0), cell.corner(v, 1, 1, 0), c111, 1 - d.r, d.r - d.g, d.g - d.b, d.b);
        if (d.r > d.b) return weighted(c000, cell.corner(v, 1, 0, 0), cell.corner(v, 1, 0, 1), c111, 1 - d.r, d.r - d.b, d.b - d.g, d.g);
        return weighted(c000, cell.corner(v, 0, 0, 1), cell.corner(v, 1, 0, 1), c111, 1 - d.b, d.b - d.r, d.r - d.g, d.g);
    }
    if (d.b > d.g) return weighted(c000, cell.corner(v, 0, 0, 1), cell.corner(v, 0, 1, 1), c111, 1 - d.b, d.b - d.g, d.g - d.r, d.r);
    if (d.b > d.r) return weighted(c000, cell.corner(v, 0, 1, 0), cell.corner(v, 0, 1, 1), c111, 1 - d.g, d.g - d.b, d.b - d.r, d.r);
    return weighted(c000, cell.corner(v, 0, 1, 0), cell.corner(v, 1, 1, 0), c111, 1 - d.g, d.g - d.r, d.r - d.b, d.b);
}

fn mix(a: Rgb, b: Rgb, amount: f32) Rgb {
    return .{ .r = a.r + (b.r - a.r) * amount, .g = a.g + (b.g - a.g) * amount, .b = a.b + (b.b - a.b) * amount };
}
fn weighted(a: Rgb, b: Rgb, c: Rgb, d: Rgb, wa: f32, wb: f32, wc: f32, wd: f32) Rgb {
    return .{ .r = a.r * wa + b.r * wb + c.r * wc + d.r * wd, .g = a.g * wa + b.g * wb + c.g * wc + d.g * wd, .b = a.b * wa + b.b * wb + c.b * wc + d.b * wd };
}
fn previous(value: f32) usize {
    return @intFromFloat(@floor(value));
}
fn next(value: usize, size: usize) usize {
    return @min(value + 1, size - 1);
}
fn nearest(value: f32) usize {
    return @intFromFloat(@floor(value + 0.5));
}

pub fn toByte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255.0));
}

pub const max_workers = 64;
/// Measured on an 8-core/16-thread CPU, tetrahedral (the default mode) runs ~22% faster on all
/// 16 logical CPUs than on 8. Past 16, per-frame thread start-up outweighs the gain for typical
/// frame sizes.
pub const default_max_workers = 16;

/// A joinable worker thread. On Windows it uses kernel32 directly: Zig 0.16's `std.Thread.join`
/// waits with a huge negative timeout that Wine answers with STATUS_TIMEOUT, which panics.
const Worker = if (@import("builtin").os.tag == .windows) struct {
    handle: *anyopaque,

    extern "kernel32" fn CreateThread(attributes: ?*anyopaque, stack: usize, start: *const fn (?*anyopaque) callconv(.winapi) u32, parameter: ?*anyopaque, flags: u32, id: ?*u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn WaitForSingleObject(handle: *anyopaque, milliseconds: u32) callconv(.winapi) u32;
    extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) c_int;

    fn spawn(comptime Context: type, comptime function: fn (*const Context) void, context: *const Context) !@This() {
        const start = struct {
            fn call(parameter: ?*anyopaque) callconv(.winapi) u32 {
                function(@ptrCast(@alignCast(parameter)));
                return 0;
            }
        }.call;
        return .{ .handle = CreateThread(null, 0, start, @constCast(context), 0, null) orelse return error.SpawnFailed };
    }

    fn join(self: @This()) void {
        _ = WaitForSingleObject(self.handle, 0xffff_ffff);
        _ = CloseHandle(self.handle);
    }
} else struct {
    thread: std.Thread,

    fn spawn(comptime Context: type, comptime function: fn (*const Context) void, context: *const Context) !@This() {
        return .{ .thread = try std.Thread.spawn(.{}, function, .{context}) };
    }

    fn join(self: @This()) void {
        self.thread.join();
    }
};
/// Each worker gets at least this many pixels, so small frames use fewer threads (or just one).
pub const min_pixels_per_worker = 32_768;

/// Applies `lut` in place. `Pixel` is any struct with `r`, `g`, `b`, `a: u8` fields, in any
/// order. Pixels with zero alpha are left untouched. Blending happens in float and rounds once.
pub fn processPixels(comptime Pixel: type, pixels: []Pixel, width: usize, height: usize, lut: *const Lut, mode: Mode, strength: f32) void {
    processPixelsWith(Pixel, pixels, width, height, lut, mode, strength, defaultWorkers());
}

/// Upper bound on the threads `processPixels` uses: every logical CPU, up to `default_max_workers`.
pub fn defaultWorkers() usize {
    return @min(std.Thread.getCpuCount() catch 1, default_max_workers);
}

/// `processPixels` with an explicit thread count, for benchmarks and tests.
pub fn processPixelsWith(comptime Pixel: type, pixels: []Pixel, width: usize, height: usize, lut: *const Lut, mode: Mode, strength: f32, threads: usize) void {
    std.debug.assert(pixels.len >= width * height);
    if (!(strength > 0) or width == 0 or height == 0) return;
    const job = Job(Pixel){ .pixels = pixels.ptr, .width = width, .sampler = .init(lut), .strength = @min(strength, 1) };
    switch (mode) {
        inline else => |comptime_mode| if (job.strength == 1) job.run(comptime_mode, false, height, threads) else job.run(comptime_mode, true, height, threads),
    }
}

fn Job(comptime Pixel: type) type {
    return struct {
        pixels: [*]Pixel,
        width: usize,
        sampler: Sampler,
        strength: f32,

        const Self = @This();

        const Range = struct { job: *const Self, start: usize, end: usize };

        fn run(self: *const Self, comptime mode: Mode, comptime blend: bool, height: usize, threads: usize) void {
            const workers = std.math.clamp(@min(threads, self.width * height / min_pixels_per_worker), 1, @min(max_workers, height));
            const entry = struct {
                fn call(range: *const Range) void {
                    range.job.rows(mode, blend, range.start, range.end);
                }
            }.call;
            var ranges: [max_workers]Range = undefined;
            var handles: [max_workers - 1]?Worker = @splat(null);
            for (1..workers) |worker| {
                ranges[worker] = .{ .job = self, .start = height * worker / workers, .end = height * (worker + 1) / workers };
                handles[worker - 1] = Worker.spawn(Range, entry, &ranges[worker]) catch blk: {
                    entry(&ranges[worker]);
                    break :blk null;
                };
            }
            self.rows(mode, blend, 0, height / workers);
            for (handles[0 .. workers - 1]) |handle| if (handle) |worker| worker.join();
        }

        fn rows(self: *const Self, comptime mode: Mode, comptime blend: bool, start: usize, end: usize) void {
            // Locals: the u8 pixel stores could alias `self`, which would force reloads per pixel.
            const sampler = self.sampler;
            const strength = self.strength;
            const keep = (1 - strength) / 255.0;
            for (self.pixels[start * self.width .. end * self.width]) |*pixel| {
                if (pixel.a == 0) continue;
                const input = Rgb{ .r = @floatFromInt(pixel.r), .g = @floatFromInt(pixel.g), .b = @floatFromInt(pixel.b) };
                const output = sampler.sample(mode, input);
                if (blend) {
                    pixel.r = toByte(output.r * strength + input.r * keep);
                    pixel.g = toByte(output.g * strength + input.g * keep);
                    pixel.b = toByte(output.b * strength + input.b * keep);
                } else {
                    pixel.r = toByte(output.r);
                    pixel.g = toByte(output.g);
                    pixel.b = toByte(output.b);
                }
            }
        }
    };
}
