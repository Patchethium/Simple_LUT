//! Loads Simple_LUT.auf2 the way AviUtl2 does, runs proc_video on a synthetic frame for every
//! interpolation mode, and checks the result against lut_math run in-process.
//! Usage: aviutl2_harness.exe <Simple_LUT.auf2> <lut file>
const std = @import("std");
const plugin = @import("aviutl2");
const lut_math = plugin.lut_math;
const win32 = plugin.win32;
const Pixel = plugin.Pixel;

extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

const width = 320;
const height = 240; // 76 800 pixels: above the threading threshold.
var frame: [width * height]Pixel = undefined;
var result: [width * height]Pixel = undefined;
var result_size: [2]c_int = .{ 0, 0 };

fn getImage(buffer: [*]Pixel) callconv(.c) void {
    @memcpy(buffer[0..frame.len], &frame);
}

fn setImage(buffer: [*]const Pixel, w: c_int, h: c_int) callconv(.c) void {
    result_size = .{ w, h };
    @memcpy(&result, buffer[0..result.len]);
}

fn symbol(module: *anyopaque, name: [*:0]const u8, comptime T: type) !T {
    return @ptrCast(GetProcAddress(module, name) orelse return error.MissingExport);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.Usage;
    const plugin_path = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, args[1]);
    const lut_path = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, args[2]);

    const module = LoadLibraryW(plugin_path) orelse return error.LoadLibraryFailed;
    const initialize = try symbol(module, "InitializePlugin", *const fn (u32) callconv(.c) bool);
    const uninitialize = try symbol(module, "UninitializePlugin", *const fn () callconv(.c) void);
    const get_table = try symbol(module, "GetFilterPluginTable", *const fn () callconv(.c) *plugin.FilterTable);
    if (!initialize(2001000)) return error.InitializeFailed;
    defer uninitialize();
    const table = get_table();
    const file_item: *plugin.FileItem = @ptrCast(@alignCast(table.items[0].?));
    const strength_item: *plugin.TrackItem = @ptrCast(@alignCast(table.items[1].?));
    const mode_item: *plugin.SelectItem = @ptrCast(@alignCast(table.items[2].?));
    if (!std.mem.eql(u16, std.mem.span(file_item.type_name), std.unicode.utf8ToUtf16LeStringLiteral("file"))) return error.UnexpectedItems;

    for (&frame, 0..) |*pixel, index| {
        const x = index % width;
        const y = index / width;
        pixel.* = .{ .r = @intCast(x * 255 / (width - 1)), .g = @intCast(y * 255 / (height - 1)), .b = @intCast((x + y) % 256), .a = if (x == 7) 0 else 255 };
    }
    const bytes = try win32.readFile(lut_path.ptr);
    var lut = try lut_math.parse(allocator, bytes, lut_math.formatFromPath(u16, lut_path).?);
    defer lut.deinit(allocator);

    const object = plugin.ObjectInfo{ .id = 1, .frame = 0, .frame_total = 1, .time = 0, .time_total = 1, .width = width, .height = height };
    var video = plugin.VideoProc{ .scene = null, .object = &object, .get_image_data = getImage, .set_image_data = setImage };
    file_item.value = lut_path.ptr;
    for ([_]lut_math.Mode{ .nearest, .tetrahedral, .trilinear }) |mode| {
        for ([_]f64{ 1.0, 0.8 }) |amount| {
            mode_item.value = @intFromEnum(mode);
            strength_item.value = amount;
            if (!table.proc_video(&video)) return error.ProcVideoFailed;
            var expected = frame;
            lut_math.processPixels(Pixel, &expected, width, height, &lut, mode, @floatCast(amount));
            if (result_size[0] != width or result_size[1] != height) return error.WrongSize;
            if (!std.mem.eql(u8, std.mem.asBytes(&expected), std.mem.asBytes(&result))) return error.OutputMismatch;
            std.debug.print("ok  {s} strength {d}\n", .{ @tagName(mode), amount });
        }
    }

    // A missing file must fail cleanly rather than crash or reuse the previous LUT.
    file_item.value = std.unicode.utf8ToUtf16LeStringLiteral("does-not-exist.cube");
    if (table.proc_video(&video)) return error.MissingFileAccepted;
    std.debug.print("ok  missing file rejected\n", .{});
}
