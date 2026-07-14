const std = @import("std");

pub const Rgb = extern struct { r: f32, g: f32, b: f32 };
pub const max_level = 64;
pub const Lut = extern struct {
    values: [max_level][max_level][max_level]Rgb,
    size: c_int,
};

pub fn toByte(value: f32) u8 {
    return @intFromFloat(@round(@min(@max(value, 0), 1) * 255.0));
}

pub fn interpolate(comptime Context: type, context: *const Context, input: Rgb, mode: c_int, comptime lookup: fn (*const Context, usize, usize, usize) Rgb) Rgb {
    const size: usize = @intCast(context.size);
    const scale = @as(f32, @floatFromInt(size)) / 256.0;
    const point = Rgb{ .r = input.r * scale, .g = input.g * scale, .b = input.b * scale };
    if (mode == 1) return lookup(context, nearest(point.r, size), nearest(point.g, size), nearest(point.b, size));
    return if (mode == 3) trilinear(Context, context, point, lookup) else tetrahedral(Context, context, point, lookup);
}

fn trilinear(comptime Context: type, context: *const Context, point: Rgb, comptime lookup: fn (*const Context, usize, usize, usize) Rgb) Rgb {
    const size: usize = @intCast(context.size);
    const r0 = previous(point.r);
    const g0 = previous(point.g);
    const b0 = previous(point.b);
    const r1 = next(r0, size);
    const g1 = next(g0, size);
    const b1 = next(b0, size);
    const dr = point.r - @as(f32, @floatFromInt(r0));
    const dg = point.g - @as(f32, @floatFromInt(g0));
    const db = point.b - @as(f32, @floatFromInt(b0));
    return mix(mix(mix(lookup(context, r0, g0, b0), lookup(context, r1, g0, b0), dr), mix(lookup(context, r0, g1, b0), lookup(context, r1, g1, b0), dr), dg), mix(mix(lookup(context, r0, g0, b1), lookup(context, r1, g0, b1), dr), mix(lookup(context, r0, g1, b1), lookup(context, r1, g1, b1), dr), dg), db);
}

fn tetrahedral(comptime Context: type, context: *const Context, point: Rgb, comptime lookup: fn (*const Context, usize, usize, usize) Rgb) Rgb {
    const size: usize = @intCast(context.size);
    const r0 = previous(point.r);
    const g0 = previous(point.g);
    const b0 = previous(point.b);
    const r1 = next(r0, size);
    const g1 = next(g0, size);
    const b1 = next(b0, size);
    const d = Rgb{ .r = point.r - @as(f32, @floatFromInt(r0)), .g = point.g - @as(f32, @floatFromInt(g0)), .b = point.b - @as(f32, @floatFromInt(b0)) };
    const c000 = lookup(context, r0, g0, b0);
    const c111 = lookup(context, r1, g1, b1);
    if (d.r > d.g) {
        if (d.g > d.b) return weighted(c000, lookup(context, r1, g0, b0), lookup(context, r1, g1, b0), c111, 1 - d.r, d.r - d.g, d.g - d.b, d.b);
        if (d.r > d.b) return weighted(c000, lookup(context, r1, g0, b0), lookup(context, r1, g0, b1), c111, 1 - d.r, d.r - d.b, d.b - d.g, d.g);
        return weighted(c000, lookup(context, r0, g0, b1), lookup(context, r1, g0, b1), c111, 1 - d.b, d.b - d.r, d.r - d.g, d.g);
    }
    if (d.b > d.g) return weighted(c000, lookup(context, r0, g0, b1), lookup(context, r0, g1, b1), c111, 1 - d.b, d.b - d.g, d.g - d.r, d.r);
    if (d.b > d.r) return weighted(c000, lookup(context, r0, g1, b0), lookup(context, r0, g1, b1), c111, 1 - d.g, d.g - d.b, d.b - d.r, d.r);
    return weighted(c000, lookup(context, r0, g1, b0), lookup(context, r1, g1, b0), c111, 1 - d.g, d.g - d.r, d.r - d.b, d.b);
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
fn nearest(value: f32, size: usize) usize {
    return @min(@as(usize, @intFromFloat(@floor(value + 0.5))), size - 1);
}

const File = opaque {};
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*File;
extern "c" fn fclose(file: *File) c_int;
extern "c" fn fgets(buffer: [*]u8, length: c_int, file: *File) ?[*]u8;

pub fn loadLut(path: [*:0]const u8) ?*Lut {
    const name = std.mem.span(path);
    if (std.ascii.endsWithIgnoreCase(name, ".cube")) return parseCube(path);
    if (std.ascii.endsWithIgnoreCase(name, ".3dl")) return parse3dl(path);
    if (std.ascii.endsWithIgnoreCase(name, ".m3d")) return parseM3d(path);
    return null;
}

fn parseCube(path: [*:0]const u8) ?*Lut {
    const file = fopen(path, "rb") orelse return null;
    defer _ = fclose(file);
    const lut = std.heap.c_allocator.create(Lut) catch return null;
    errdefer std.heap.c_allocator.destroy(lut);
    lut.* = std.mem.zeroes(Lut);
    var line: [512]u8 = undefined;
    var domain_min = Rgb{ .r = 0, .g = 0, .b = 0 };
    var domain_max = Rgb{ .r = 1, .g = 1, .b = 1 };
    var count: usize = 0;
    while (fgets(&line, line.len, file)) |raw| {
        var tokens = std.mem.tokenizeAny(u8, std.mem.sliceTo(raw, 0), " \t\r\n");
        const first = tokens.next() orelse continue;
        if (std.mem.eql(u8, first, "LUT_3D_SIZE")) {
            const size = std.fmt.parseInt(c_int, tokens.next() orelse return null, 10) catch return null;
            if (size < 2 or size > max_level) return null;
            lut.size = size;
        } else if (std.mem.eql(u8, first, "DOMAIN_MIN")) {
            domain_min = parseRgb(&tokens) orelse return null;
        } else if (std.mem.eql(u8, first, "DOMAIN_MAX")) {
            domain_max = parseRgb(&tokens) orelse return null;
        } else if (lut.size != 0 and first[0] != '#' and !std.mem.eql(u8, first, "TITLE")) {
            const rgb = parseRgbFirst(first, &tokens) orelse return null;
            const size: usize = @intCast(lut.size);
            if (count >= size * size * size) return null;
            const r = count % size;
            const g = count / size % size;
            const b = count / (size * size);
            lut.values[r][g][b] = .{ .r = rgb.r * (domain_max.r - domain_min.r), .g = rgb.g * (domain_max.g - domain_min.g), .b = rgb.b * (domain_max.b - domain_min.b) };
            count += 1;
        }
    }
    const size: usize = @intCast(lut.size);
    if (lut.size == 0 or count != size * size * size) return null;
    return lut;
}

fn parse3dl(path: [*:0]const u8) ?*Lut {
    const file = fopen(path, "rb") orelse return null;
    defer _ = fclose(file);
    const lut = allocateLut(17) orelse return null;
    errdefer std.heap.c_allocator.destroy(lut);
    var line: [512]u8 = undefined;
    var index: usize = 0;
    while (index < 17 * 17 * 17) {
        const rgb = while (true) {
            const text = nextDataLine(file, &line) orelse return null;
            var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
            const r = std.fmt.parseInt(c_int, tokens.next() orelse continue, 10) catch continue;
            const g = std.fmt.parseInt(c_int, tokens.next() orelse continue, 10) catch continue;
            const b = std.fmt.parseInt(c_int, tokens.next() orelse continue, 10) catch continue;
            break .{ .r = r, .g = g, .b = b };
        };
        const x = index % 17;
        const y = index / 17 % 17;
        const z = index / (17 * 17);
        lut.values[z][y][x] = .{ .r = @as(f32, @floatFromInt(rgb.r)) / 4096.0, .g = @as(f32, @floatFromInt(rgb.g)) / 4096.0, .b = @as(f32, @floatFromInt(rgb.b)) / 4096.0 };
        index += 1;
    }
    return lut;
}

fn parseM3d(path: [*:0]const u8) ?*Lut {
    const file = fopen(path, "rb") orelse return null;
    defer _ = fclose(file);
    var line: [512]u8 = undefined;
    var input_count: c_int = -1;
    var output_count: c_int = -1;
    var map = [3]usize{ 0, 1, 2 };
    while (fgets(&line, line.len, file)) |raw| {
        const text = std.mem.trim(u8, std.mem.sliceTo(raw, 0), " \t\r\n");
        if (std.mem.startsWith(u8, text, "in")) input_count = std.fmt.parseInt(c_int, std.mem.trim(u8, text[2..], " \t"), 0) catch return null else if (std.mem.startsWith(u8, text, "out")) output_count = std.fmt.parseInt(c_int, std.mem.trim(u8, text[3..], " \t"), 0) catch return null else if (std.mem.startsWith(u8, text, "values")) {
            var values = std.mem.tokenizeAny(u8, text[6..], " \t");
            for (0..3) |index| {
                const name = values.next() orelse return null;
                map[index] = switch (name[0]) {
                    'r' => 0,
                    'g' => 1,
                    'b' => 2,
                    else => return null,
                };
            }
        }
    }
    if (input_count < 2 or output_count < 2 or input_count > max_level * max_level * max_level) return null;
    var size: c_int = 1;
    while (size * size * size < input_count) : (size += 1) {}
    if (size > max_level) return null;
    const lut = allocateLut(size) orelse return null;
    errdefer std.heap.c_allocator.destroy(lut);
    if (fseek(file, 0, 0) != 0) return null;
    var index: usize = 0;
    const total: usize = @as(usize, @intCast(size * size * size));
    while (index < total) {
        const text = nextDataLine(file, &line) orelse return null;
        if (std.mem.startsWith(u8, text, "in") or std.mem.startsWith(u8, text, "out") or std.mem.startsWith(u8, text, "values")) continue;
        var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
        var values: [3]f32 = undefined;
        for (0..3) |channel| values[channel] = std.fmt.parseFloat(f32, tokens.next() orelse return null) catch return null;
        const x = index % @as(usize, @intCast(size));
        const y = index / @as(usize, @intCast(size)) % @as(usize, @intCast(size));
        const z = index / @as(usize, @intCast(size * size));
        const scale = 1.0 / @as(f32, @floatFromInt(output_count - 1));
        lut.values[z][y][x] = .{ .r = values[map[0]] * scale, .g = values[map[1]] * scale, .b = values[map[2]] * scale };
        index += 1;
    }
    return lut;
}

fn allocateLut(size: c_int) ?*Lut {
    const lut = std.heap.c_allocator.create(Lut) catch return null;
    lut.* = std.mem.zeroes(Lut);
    lut.size = size;
    return lut;
}

fn nextDataLine(file: *File, line: *[512]u8) ?[]const u8 {
    while (fgets(line, line.len, file)) |raw| {
        const text = std.mem.trim(u8, std.mem.sliceTo(raw, 0), " \t\r\n");
        if (text.len != 0 and text[0] != '#') return text;
    }
    return null;
}

extern "c" fn fseek(file: *File, offset: c_long, origin: c_int) c_int;

fn parseRgb(tokens: anytype) ?Rgb {
    return .{ .r = std.fmt.parseFloat(f32, tokens.next() orelse return null) catch return null, .g = std.fmt.parseFloat(f32, tokens.next() orelse return null) catch return null, .b = std.fmt.parseFloat(f32, tokens.next() orelse return null) catch return null };
}
fn parseRgbFirst(first: []const u8, tokens: anytype) ?Rgb {
    return .{ .r = std.fmt.parseFloat(f32, first) catch return null, .g = std.fmt.parseFloat(f32, tokens.next() orelse return null) catch return null, .b = std.fmt.parseFloat(f32, tokens.next() orelse return null) catch return null };
}
