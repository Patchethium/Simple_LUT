const std = @import("std");
const lut_math = @import("lut_math.zig");
pub const c = @cImport({
    @cInclude("png.h");
});

pub const Pixel = extern struct { r: u8, g: u8, b: u8, a: u8 };

const usage =
    \\Usage: {0s} <input.png> <lut.cube|lut.3dl|lut.m3d> <output.png> [nearest|tetrahedral|trilinear] [strength]
    \\       {0s} --diff <a.png> <b.png> [max-allowed]
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const program = if (args.len > 0) args[0] else "simple-lut";

    if (args.len >= 2 and std.mem.eql(u8, args[1], "--diff")) {
        if (args.len < 4 or args.len > 5) return usageError(program);
        const allowed = if (args.len == 5) try std.fmt.parseInt(u8, args[4], 10) else 1;
        return diff(allocator, args[2], args[3], allowed);
    }

    if (args.len < 4 or args.len > 6) return usageError(program);
    const mode = if (args.len >= 5) parseMode(args[4]) orelse return usageError(program) else .tetrahedral;
    const strength = if (args.len == 6) try std.fmt.parseFloat(f32, args[5]) else 1;
    var lut = lut_math.loadFile(init.io, allocator, args[2]) catch |err| {
        std.debug.print("Cannot load LUT {s}: {s}\n", .{ args[2], @errorName(err) });
        return err;
    };
    defer lut.deinit(allocator);

    const image = try readPng(allocator, args[1]);
    lut_math.processPixels(Pixel, image.pixels, image.width, image.height, &lut, mode, strength);
    try writePng(args[3], image);
}

fn usageError(program: []const u8) error{InvalidArguments} {
    std.debug.print(usage, .{program});
    return error.InvalidArguments;
}

fn parseMode(value: []const u8) ?lut_math.Mode {
    return std.meta.stringToEnum(lut_math.Mode, value);
}

pub const Image = struct { width: usize, height: usize, pixels: []Pixel };

pub fn readPng(allocator: std.mem.Allocator, path: []const u8) !Image {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var image: c.png_image = std.mem.zeroes(c.png_image);
    image.version = c.PNG_IMAGE_VERSION;
    if (c.png_image_begin_read_from_file(&image, path_z.ptr) == 0) return error.PngReadFailed;
    defer c.png_image_free(&image);
    image.format = c.PNG_FORMAT_RGBA;
    const width: usize = image.width;
    const height: usize = image.height;
    const pixels = try allocator.alloc(Pixel, width * height);
    errdefer allocator.free(pixels);
    if (c.png_image_finish_read(&image, null, pixels.ptr, 0, null) == 0) return error.PngReadFailed;
    return .{ .width = width, .height = height, .pixels = pixels };
}

fn writePng(path: []const u8, source: Image) !void {
    var path_buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buffer, "{s}", .{path});
    var image: c.png_image = std.mem.zeroes(c.png_image);
    image.version = c.PNG_IMAGE_VERSION;
    image.width = @intCast(source.width);
    image.height = @intCast(source.height);
    image.format = c.PNG_FORMAT_RGBA;
    if (c.png_image_write_to_file(&image, path_z.ptr, 0, source.pixels.ptr, 0, null) == 0) return error.PngWriteFailed;
}

/// Compares the RGB channels of two same-sized PNGs; fails when any channel differs by more than `allowed`.
fn diff(allocator: std.mem.Allocator, a_path: []const u8, b_path: []const u8, allowed: u8) !void {
    const a = try readPng(allocator, a_path);
    const b = try readPng(allocator, b_path);
    if (a.width != b.width or a.height != b.height) return error.SizeMismatch;
    var largest: u8 = 0;
    var total: u64 = 0;
    for (a.pixels, b.pixels) |left, right| {
        for ([_]u8{ left.r, left.g, left.b }, [_]u8{ right.r, right.g, right.b }) |x, y| {
            const difference = @max(x, y) - @min(x, y);
            largest = @max(largest, difference);
            total += difference;
        }
    }
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(a.pixels.len * 3));
    std.debug.print("mean {d:.3} max {d}\n", .{ mean, largest });
    if (largest > allowed) return error.DifferenceTooLarge;
}
