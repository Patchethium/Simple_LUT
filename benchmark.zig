const std = @import("std");
const lut_lib = @import("main.zig");
const c = @cImport({
    @cInclude("png.h");
    @cInclude("time.h");
});

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.args, allocator);
    defer args.deinit();
    _ = args.next();
    const image_path = args.next() orelse "test/sample.png";
    const lut_path = args.next() orelse "test/MagicHour.cube";
    const iterations = if (args.next()) |value| try std.fmt.parseInt(usize, value, 10) else 10;
    if (iterations == 0 or args.next() != null) return error.InvalidArguments;

    const lut = try lut_lib.loadLut(allocator, lut_path);
    const image_z = try allocator.dupeZ(u8, image_path);
    var image: c.png_image = std.mem.zeroes(c.png_image);
    image.version = c.PNG_IMAGE_VERSION;
    if (c.png_image_begin_read_from_file(&image, image_z.ptr) == 0) return error.PngReadFailed;
    defer c.png_image_free(&image);
    image.format = c.PNG_FORMAT_RGBA;

    const byte_count = @as(usize, @intCast(image.width)) * @as(usize, @intCast(image.height)) * 4;
    const source = try allocator.alloc(u8, byte_count);
    const destination = try allocator.alloc(u8, byte_count);
    if (c.png_image_finish_read(&image, null, source.ptr, 0, null) == 0) return error.PngReadFailed;

    std.debug.print(
        "Benchmarking {d} x {d} image, {d} iterations, up to {d} workers; PNG decoding and LUT loading excluded.\n",
        .{ image.width, image.height, iterations, workerCount(@as(usize, @intCast(image.width)) * @as(usize, @intCast(image.height))) },
    );
    inline for (.{ lut_lib.Interpolation.nearest, .tetrahedral, .trilinear }) |mode| {
        const elapsed_ns = benchmark(&lut, source, destination, @intCast(image.width), @intCast(image.height), mode, iterations);
        const pixels = @as(f64, @floatFromInt((source.len / 4) * iterations));
        const seconds = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
        std.debug.print(
            "{s:11} {d:.3} ms/frame  {d:.2} MPixel/s\n",
            .{ @tagName(mode), seconds * 1000.0 / @as(f64, @floatFromInt(iterations)), pixels / seconds / 1_000_000.0 },
        );
    }
}

const max_workers = 8;
const Work = struct {
    lut: *const lut_lib.Lut,
    source: [*]const u8,
    destination: [*]u8,
    width: usize,
    start_row: usize,
    end_row: usize,
    mode: lut_lib.Interpolation,
};

fn benchmark(lut: *const lut_lib.Lut, source: []const u8, destination: []u8, width: usize, height: usize, mode: lut_lib.Interpolation, iterations: usize) u64 {
    const start = monotonicNs();
    var iteration: usize = 0;
    while (iteration < iterations) : (iteration += 1) {
        processPixels(lut, source.ptr, destination.ptr, width, height, mode);
    }
    std.mem.doNotOptimizeAway(destination[0]);
    return monotonicNs() - start;
}

fn workerCount(pixel_count: usize) usize {
    if (pixel_count < 65_536) return 1;
    return @min(std.Thread.getCpuCount() catch 1, max_workers);
}

fn processPixels(lut: *const lut_lib.Lut, source: [*]const u8, destination: [*]u8, width: usize, height: usize, mode: lut_lib.Interpolation) void {
    const worker_count = @min(workerCount(width * height), height);
    if (worker_count == 1) {
        const work = Work{ .lut = lut, .source = source, .destination = destination, .width = width, .start_row = 0, .end_row = height, .mode = mode };
        processRows(&work);
        return;
    }

    var work: [max_workers]Work = undefined;
    var threads: [max_workers - 1]std.Thread = undefined;
    var spawned: [max_workers - 1]bool = [_]bool{false} ** (max_workers - 1);
    for (0..worker_count) |index| {
        work[index] = .{
            .lut = lut,
            .source = source,
            .destination = destination,
            .width = width,
            .start_row = height * index / worker_count,
            .end_row = height * (index + 1) / worker_count,
            .mode = mode,
        };
    }
    for (1..worker_count) |index| {
        threads[index - 1] = std.Thread.spawn(.{}, processRows, .{&work[index]}) catch {
            processRows(&work[index]);
            continue;
        };
        spawned[index - 1] = true;
    }
    processRows(&work[0]);
    for (1..worker_count) |index| {
        if (spawned[index - 1]) threads[index - 1].join();
    }
}

fn processRows(work: *const Work) void {
    for (work.start_row * work.width .. work.end_row * work.width) |index| {
        const offset = index * 4;
        work.destination[offset + 3] = work.source[offset + 3];
        if (work.source[offset + 3] == 0) {
            work.destination[offset] = work.source[offset];
            work.destination[offset + 1] = work.source[offset + 1];
            work.destination[offset + 2] = work.source[offset + 2];
            continue;
        }
        const output = lut_lib.applyLut(work.lut, .{
            .r = @floatFromInt(work.source[offset]),
            .g = @floatFromInt(work.source[offset + 1]),
            .b = @floatFromInt(work.source[offset + 2]),
        }, work.mode);
        work.destination[offset] = lut_lib.toByte(output.r);
        work.destination[offset + 1] = lut_lib.toByte(output.g);
        work.destination[offset + 2] = lut_lib.toByte(output.b);
    }
}

fn monotonicNs() u64 {
    var timestamp: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &timestamp) != 0) unreachable;
    return @as(u64, @intCast(timestamp.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(timestamp.tv_nsec));
}
