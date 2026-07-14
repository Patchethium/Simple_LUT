const std = @import("std");
const lut_math = @import("lut_math.zig");
const L = std.unicode.utf8ToUtf16LeStringLiteral;

const Rgb = lut_math.Rgb;
const Pixel = extern struct { r: u8, g: u8, b: u8, a: u8 };
const Lut = lut_math.Lut;
const ObjectInfo = extern struct {
    id: i64, frame: c_int, frame_total: c_int, time: f64, time_total: f64,
    width: c_int, height: c_int,
};
const VideoProc = extern struct {
    scene: ?*const anyopaque,
    object: *const ObjectInfo,
    get_image_data: *const fn ([*]Pixel) callconv(.c) void,
    set_image_data: *const fn ([*]const Pixel, c_int, c_int) callconv(.c) void,
};
const TrackItem = extern struct {
    type_name: [*:0]const u16 = L("track2").ptr,
    name: [*:0]const u16,
    value: f64,
    start: f64,
    end: f64,
    step: f64,
    zero_display: ?[*:0]const u16,
    slider_ratio: f64,
};
const SelectOption = extern struct { name: ?[*:0]const u16, value: c_int };
const SelectItem = extern struct {
    type_name: [*:0]const u16 = L("select").ptr,
    name: [*:0]const u16,
    value: c_int,
    options: [*]const SelectOption,
};
const FileItem = extern struct {
    type_name: [*:0]const u16 = L("file").ptr,
    name: [*:0]const u16,
    value: [*:0]const u16,
    filter: [*:0]const u16,
};
const FilterTable = extern struct {
    flag: c_int,
    name: [*:0]const u16,
    label: [*:0]const u16,
    information: [*:0]const u16,
    items: [*]?*anyopaque,
    proc_video: *const fn (*VideoProc) callconv(.c) bool,
    proc_audio: ?*const anyopaque,
};

const work_limit = 8;
var cached_lut: ?*Lut = null;
var cached_path: [32768]u16 = [_]u16{0} ** 32768;

var strength = TrackItem{ .name = L("Strength").ptr, .value = 1.0, .start = 0.0, .end = 1.0, .step = 0.01, .zero_display = null, .slider_ratio = 1.0 };
var modes = [_]SelectOption{
    .{ .name = L("Nearest").ptr, .value = 1 },
    .{ .name = L("Tetrahedral").ptr, .value = 2 },
    .{ .name = L("Trilinear").ptr, .value = 3 },
    .{ .name = null, .value = 0 },
};
var interpolation = SelectItem{ .name = L("Interpolation").ptr, .value = 2, .options = &modes };
var lut_file = FileItem{ .name = L("3D LUT").ptr, .value = L("").ptr, .filter = L("3D LUT (*.cube;*.3dl;*.m3d)\x00*.cube;*.3dl;*.m3d\x00").ptr };
var items = [_]?*anyopaque{ @ptrCast(&lut_file), @ptrCast(&strength), @ptrCast(&interpolation), null };
var table = FilterTable{
    .flag = 1 | 8,
    .name = L("Simple LUT").ptr,
    .label = L("Simple LUT").ptr,
    .information = L("3D LUT filter (.cube, .3dl, .m3d)").ptr,
    .items = &items,
    .proc_video = processVideo,
    .proc_audio = null,
};

extern "kernel32" fn WideCharToMultiByte(code_page: u32, flags: u32, wide: [*]const u16, wide_len: c_int, utf8: ?[*]u8, utf8_len: c_int, default_char: ?*const u8, used_default: ?*c_int) callconv(.winapi) c_int;

pub export fn InitializePlugin(_: u32) callconv(.c) bool {
    return true;
}

pub export fn UninitializePlugin() callconv(.c) void {
    if (cached_lut) |lut| std.heap.c_allocator.destroy(lut);
    cached_lut = null;
}

pub export fn GetFilterPluginTable() callconv(.c) *FilterTable {
    return &table;
}

fn processVideo(video: *VideoProc) callconv(.c) bool {
    const width: usize = @intCast(video.object.width);
    const height: usize = @intCast(video.object.height);
    if (width == 0 or height == 0 or lut_file.value[0] == 0) return true;
    const lut = getLut(lut_file.value) orelse return false;
    const pixels = std.heap.c_allocator.alloc(Pixel, width * height) catch return false;
    defer std.heap.c_allocator.free(pixels);
    video.get_image_data(pixels.ptr);
    processPixels(pixels, width, height, lut, interpolation.value, @floatCast(strength.value));
    video.set_image_data(pixels.ptr, @intCast(width), @intCast(height));
    return true;
}

fn getLut(path: [*:0]const u16) ?*Lut {
    if (cached_lut != null and equalWide(&cached_path, path)) return cached_lut;
    const utf8_path = wideToUtf8(path) orelse return null;
    defer std.heap.c_allocator.free(utf8_path);
    const loaded = lut_math.loadLut(utf8_path) orelse return null;
    if (cached_lut) |old| std.heap.c_allocator.destroy(old);
    cached_lut = loaded;
    copyWide(&cached_path, path);
    return loaded;
}

fn wideToUtf8(path: [*:0]const u16) ?[:0]u8 {
    const length = WideCharToMultiByte(65001, 0, path, -1, null, 0, null, null);
    if (length <= 1) return null;
    const result = std.heap.c_allocator.allocSentinel(u8, @intCast(length - 1), 0) catch return null;
    if (WideCharToMultiByte(65001, 0, path, -1, result.ptr, length, null, null) == 0) {
        std.heap.c_allocator.free(result);
        return null;
    }
    return result;
}

fn equalWide(a: *const [32768]u16, b: [*:0]const u16) bool {
    var index: usize = 0;
    while (a[index] == b[index]) : (index += 1) if (a[index] == 0) return true;
    return false;
}

fn copyWide(destination: *[32768]u16, source: [*:0]const u16) void {
    var index: usize = 0;
    while (index < destination.len - 1) : (index += 1) {
        destination[index] = source[index];
        if (source[index] == 0) return;
    }
    destination[destination.len - 1] = 0;
}

fn at(lut: *const Lut, r: usize, g: usize, b: usize) Rgb {
    return lut.values[r][g][b];
}

const Work = struct { pixels: [*]Pixel, start: usize, end: usize, width: usize, lut: *const Lut, mode: c_int, strength: f32 };
fn processPixels(pixels: []Pixel, width: usize, height: usize, lut: *const Lut, mode: c_int, amount: f32) void {
    const workers = @min(@min(std.Thread.getCpuCount() catch 1, work_limit), height);
    if (workers < 2 or pixels.len < 65_536) {
        const work = Work{ .pixels = pixels.ptr, .start = 0, .end = height, .width = width, .lut = lut, .mode = mode, .strength = amount };
        processRows(&work); return;
    }
    var work: [work_limit]Work = undefined;
    var threads: [work_limit - 1]std.Thread = undefined;
    var spawned: [work_limit - 1]bool = [_]bool{false} ** (work_limit - 1);
    for (0..workers) |index| work[index] = .{ .pixels = pixels.ptr, .start = height * index / workers, .end = height * (index + 1) / workers, .width = width, .lut = lut, .mode = mode, .strength = amount };
    for (1..workers) |index| {
        threads[index - 1] = std.Thread.spawn(.{}, processRows, .{&work[index]}) catch {
            processRows(&work[index]);
            continue;
        };
        spawned[index - 1] = true;
    }
    processRows(&work[0]);
    for (1..workers) |index| if (spawned[index - 1]) threads[index - 1].join();
}
fn processRows(work: *const Work) void {
    for (work.start * work.width .. work.end * work.width) |index| {
        const pixel = &work.pixels[index];
        if (pixel.a == 0) continue;
        const output = lut_math.interpolate(Lut, work.lut, .{ .r = @floatFromInt(pixel.r), .g = @floatFromInt(pixel.g), .b = @floatFromInt(pixel.b) }, work.mode, at);
        pixel.r = @intFromFloat(@round(@as(f32, @floatFromInt(lut_math.toByte(output.r))) * work.strength + @as(f32, @floatFromInt(pixel.r)) * (1 - work.strength)));
        pixel.g = @intFromFloat(@round(@as(f32, @floatFromInt(lut_math.toByte(output.g))) * work.strength + @as(f32, @floatFromInt(pixel.g)) * (1 - work.strength)));
        pixel.b = @intFromFloat(@round(@as(f32, @floatFromInt(lut_math.toByte(output.b))) * work.strength + @as(f32, @floatFromInt(pixel.b)) * (1 - work.strength)));
    }
}
