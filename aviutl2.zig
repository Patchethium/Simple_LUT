const std = @import("std");
pub const lut_math = @import("lut_math.zig");
pub const win32 = @import("win32.zig");
const sdk = @import("aviutl2_sdk.zig");
const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const Pixel = sdk.Pixel;
pub const ObjectInfo = sdk.ObjectInfo;
pub const VideoProc = sdk.VideoProc;
pub const TrackItem = sdk.TrackItem;
pub const SelectOption = sdk.SelectOption;
pub const SelectItem = sdk.SelectItem;
pub const FileItem = sdk.FileItem;
pub const FilterTable = sdk.FilterTable;

var cache: win32.SharedCache = .{};

var strength = TrackItem{ .name = L("Strength").ptr, .value = 1.0, .start = 0.0, .end = 1.0, .step = 0.01, .zero_display = null, .slider_ratio = 1.0 };
var modes = [_]SelectOption{
    .{ .name = L("Nearest").ptr, .value = @intFromEnum(lut_math.Mode.nearest) },
    .{ .name = L("Tetrahedral").ptr, .value = @intFromEnum(lut_math.Mode.tetrahedral) },
    .{ .name = L("Trilinear").ptr, .value = @intFromEnum(lut_math.Mode.trilinear) },
    .{ .name = null, .value = 0 },
};
var interpolation = SelectItem{ .name = L("Interpolation").ptr, .value = @intFromEnum(lut_math.Mode.tetrahedral), .options = &modes };
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

pub export fn InitializePlugin(_: u32) callconv(.c) bool {
    return true;
}

pub export fn UninitializePlugin() callconv(.c) void {
    cache.deinit();
}

pub export fn GetFilterPluginTable() callconv(.c) *FilterTable {
    return &table;
}

fn processVideo(video: *VideoProc) callconv(.c) bool {
    const width: usize = @intCast(@max(video.object.width, 0));
    const height: usize = @intCast(@max(video.object.height, 0));
    // Read the item values once; the host updates them before each call.
    const path = std.mem.span(lut_file.value);
    const amount: f32 = @floatCast(strength.value);
    const mode = lut_math.Mode.fromInt(interpolation.value) orelse .tetrahedral;
    if (width == 0 or height == 0 or path.len == 0 or !(amount > 0)) return true;

    const lut = cache.acquire(path) catch return false;
    defer cache.release();
    const pixels = win32.allocator.alloc(Pixel, width * height) catch return false;
    defer win32.allocator.free(pixels);
    video.get_image_data(pixels.ptr);
    lut_math.processPixels(Pixel, pixels, width, height, lut, mode, amount);
    video.set_image_data(pixels.ptr, @intCast(width), @intCast(height));
    return true;
}
