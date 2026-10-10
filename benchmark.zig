const std = @import("std");
const lut_math = @import("lut_math.zig");
const png = @import("main.zig");
const c = @cImport({
    @cInclude("time.h");
});

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const image_path = if (args.len > 1) args[1] else "test/sample.png";
    const lut_path = if (args.len > 2) args[2] else "test/MagicHour.cube";
    const iterations = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 10;
    if (iterations == 0 or args.len > 4) return error.InvalidArguments;

    var lut = try lut_math.loadFile(init.io, allocator, lut_path);
    defer lut.deinit(allocator);
    const image = try png.readPng(allocator, image_path);
    const working = try allocator.alloc(png.Pixel, image.pixels.len);

    const pixel_count = image.width * image.height;
    const workers = if (pixel_count < lut_math.parallel_threshold) 1 else @min(std.Thread.getCpuCount() catch 1, lut_math.max_workers);
    std.debug.print(
        "Benchmarking {d} x {d} image, {d} iterations, up to {d} workers; PNG decoding and LUT loading excluded.\n",
        .{ image.width, image.height, iterations, workers },
    );
    for ([_]lut_math.Mode{ .nearest, .tetrahedral, .trilinear }) |mode| {
        var elapsed_ns: u64 = 0;
        for (0..iterations) |_| {
            @memcpy(working, image.pixels);
            const start = monotonicNs();
            lut_math.processPixels(png.Pixel, working, image.width, image.height, &lut, mode, 1);
            elapsed_ns += monotonicNs() - start;
        }
        std.mem.doNotOptimizeAway(working[0]);
        const pixels = @as(f64, @floatFromInt(pixel_count * iterations));
        const seconds = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
        std.debug.print(
            "{s:11} {d:.3} ms/frame  {d:.2} MPixel/s\n",
            .{ @tagName(mode), seconds * 1000.0 / @as(f64, @floatFromInt(iterations)), pixels / seconds / 1_000_000.0 },
        );
    }
}

fn monotonicNs() u64 {
    var timestamp: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &timestamp) != 0) unreachable;
    return @as(u64, @intCast(timestamp.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(timestamp.tv_nsec));
}
