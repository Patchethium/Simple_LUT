const std = @import("std");
const lut_math = @import("lut_math.zig");
const c = @cImport({
    @cInclude("png.h");
    @cInclude("stdio.h");
});

pub const Rgb = lut_math.Rgb;
pub const Interpolation = enum { nearest, tetrahedral, trilinear };

pub const Lut = struct {
    size: usize,
    values: []Rgb,

    fn at(self: *const Lut, r: usize, g: usize, b: usize) Rgb {
        return self.values[(r * self.size + g) * self.size + b];
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.args, allocator);
    defer args.deinit();
    const program = args.next() orelse "simple-lut";
    const input_path = args.next() orelse {
        try printUsage(program);
        return error.InvalidArguments;
    };
    const lut_path = args.next() orelse {
        try printUsage(program);
        return error.InvalidArguments;
    };
    const output_path = args.next() orelse {
        try printUsage(program);
        return error.InvalidArguments;
    };
    const mode = args.next();
    if (args.next() != null) {
        try printUsage(program);
        return error.InvalidArguments;
    }
    const interpolation = if (mode) |value| try parseInterpolation(value) else .tetrahedral;
    const lut = try loadLut(allocator, lut_path);
    try transformPng(allocator, input_path, output_path, &lut, interpolation);
}

fn printUsage(program: []const u8) !void {
    std.debug.print(
        "Usage: {s} <input.png> <lut.cube|lut.3dl|lut.m3d> <output.png> [nearest|tetrahedral|trilinear]\n",
        .{program},
    );
}

fn parseInterpolation(value: []const u8) !Interpolation {
    if (std.mem.eql(u8, value, "nearest")) return .nearest;
    if (std.mem.eql(u8, value, "tetrahedral")) return .tetrahedral;
    if (std.mem.eql(u8, value, "trilinear")) return .trilinear;
    return error.InvalidInterpolation;
}

pub fn loadLut(allocator: std.mem.Allocator, path: []const u8) !Lut {
    if (std.ascii.endsWithIgnoreCase(path, ".cube")) return loadCube(allocator, path);
    const path_z = try allocator.dupeZ(u8, path);
    const fixed = lut_math.loadLut(path_z.ptr) orelse return error.InvalidLut;
    defer std.heap.c_allocator.destroy(fixed);
    const size: usize = @intCast(fixed.size);
    const values = try allocator.alloc(Rgb, size * size * size);
    for (0..size) |r| for (0..size) |g| for (0..size) |b| {
        values[(r * size + g) * size + b] = fixed.values[r][g][b];
    };
    return .{ .size = size, .values = values };
}

fn loadCube(allocator: std.mem.Allocator, path: []const u8) !Lut {
    const contents = try readFile(allocator, path);
    var size: ?usize = null;
    var domain_min = Rgb{ .r = 0, .g = 0, .b = 0 };
    var domain_max = Rgb{ .r = 1, .g = 1, .b = 1 };
    var values: ?[]Rgb = null;
    var index: usize = 0;
    var line_number: usize = 0;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
        const first = tokens.next() orelse continue;
        if (std.mem.eql(u8, first, "TITLE")) continue;
        if (std.mem.eql(u8, first, "LUT_3D_SIZE")) {
            if (size != null or values != null) return error.InvalidCube;
            const parsed_size = std.fmt.parseInt(usize, tokens.next() orelse return error.InvalidCube, 10) catch return error.InvalidCube;
            if (parsed_size < 2 or parsed_size > 64) return error.UnsupportedLutSize;
            size = parsed_size;
            values = try allocator.alloc(Rgb, parsed_size * parsed_size * parsed_size);
            continue;
        }
        if (std.mem.eql(u8, first, "DOMAIN_MIN")) {
            domain_min = try parseRgb(&tokens);
            continue;
        }
        if (std.mem.eql(u8, first, "DOMAIN_MAX")) {
            domain_max = try parseRgb(&tokens);
            continue;
        }

        const lut_values = values orelse continue;
        if (index >= lut_values.len) return error.InvalidCube;
        var rgb = parseRgbWithFirst(first, &tokens) catch {
            std.debug.print("Invalid .cube data on line {d}: {s}\n", .{ line_number, line });
            return error.InvalidCube;
        };
        rgb.r *= domain_max.r - domain_min.r;
        rgb.g *= domain_max.g - domain_min.g;
        rgb.b *= domain_max.b - domain_min.b;
        // .cube records advance red first; the original C++ stores them as lut[r][g][b].
        const r = index % size.?;
        const g = (index / size.?) % size.?;
        const b = index / (size.? * size.?);
        lut_values[(r * size.? + g) * size.? + b] = rgb;
        index += 1;
    }

    const lut_values = values orelse return error.MissingLutSize;
    if (index != lut_values.len) return error.IncompleteCube;
    return .{ .size = size.?, .values = lut_values };
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    const file = c.fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
    defer _ = c.fclose(file);
    if (c.fseek(file, 0, c.SEEK_END) != 0) return error.FileReadFailed;
    const length = c.ftell(file);
    if (length < 0 or length > 16 * 1024 * 1024) return error.FileTooLarge;
    if (c.fseek(file, 0, c.SEEK_SET) != 0) return error.FileReadFailed;
    const contents = try allocator.alloc(u8, @intCast(length));
    if (c.fread(contents.ptr, 1, contents.len, file) != contents.len) return error.FileReadFailed;
    return contents;
}

fn parseRgb(tokens: anytype) !Rgb {
    return .{
        .r = std.fmt.parseFloat(f32, tokens.next() orelse return error.InvalidCube) catch return error.InvalidCube,
        .g = std.fmt.parseFloat(f32, tokens.next() orelse return error.InvalidCube) catch return error.InvalidCube,
        .b = std.fmt.parseFloat(f32, tokens.next() orelse return error.InvalidCube) catch return error.InvalidCube,
    };
}

fn parseRgbWithFirst(first: []const u8, tokens: anytype) !Rgb {
    return .{
        .r = std.fmt.parseFloat(f32, first) catch return error.InvalidCube,
        .g = std.fmt.parseFloat(f32, tokens.next() orelse return error.InvalidCube) catch return error.InvalidCube,
        .b = std.fmt.parseFloat(f32, tokens.next() orelse return error.InvalidCube) catch return error.InvalidCube,
    };
}

fn transformPng(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, lut: *const Lut, interpolation: Interpolation) !void {
    const input_z = try allocator.dupeZ(u8, input_path);
    const output_z = try allocator.dupeZ(u8, output_path);
    var image: c.png_image = std.mem.zeroes(c.png_image);
    image.version = c.PNG_IMAGE_VERSION;
    if (c.png_image_begin_read_from_file(&image, input_z.ptr) == 0) return error.PngReadFailed;
    defer c.png_image_free(&image);

    image.format = c.PNG_FORMAT_RGBA;
    const byte_count = @as(usize, @intCast(image.width)) * @as(usize, @intCast(image.height)) * 4;
    const pixels = try allocator.alloc(u8, byte_count);
    if (c.png_image_finish_read(&image, null, pixels.ptr, 0, null) == 0) return error.PngReadFailed;

    var offset: usize = 0;
    while (offset < pixels.len) : (offset += 4) {
        if (pixels[offset + 3] == 0) continue;
        const input = Rgb{
            .r = @floatFromInt(pixels[offset]),
            .g = @floatFromInt(pixels[offset + 1]),
            .b = @floatFromInt(pixels[offset + 2]),
        };
        const output = applyLut(lut, input, interpolation);
        pixels[offset] = toByte(output.r);
        pixels[offset + 1] = toByte(output.g);
        pixels[offset + 2] = toByte(output.b);
    }

    if (c.png_image_write_to_file(&image, output_z.ptr, 0, pixels.ptr, 0, null) == 0) return error.PngWriteFailed;
}

pub fn applyLut(lut: *const Lut, input: Rgb, interpolation: Interpolation) Rgb {
    return lut_math.interpolate(Lut, lut, input, @intFromEnum(interpolation) + 1, lookup);
}

pub fn toByte(value: f32) u8 {
    return lut_math.toByte(value);
}

fn lookup(lut: *const Lut, r: usize, g: usize, b: usize) Rgb {
    return lut.at(r, g, b);
}
