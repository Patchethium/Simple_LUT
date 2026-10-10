//! Do-nothing AviUtl2 filter built the same way as Simple_LUT.auf2 (same toolchain and the same
//! hand-written structs), for checking that the host loads Zig-built plugins at all. Every call
//! is appended to C:\Users\Public\aviutl2_noop.log.
const std = @import("std");
const plugin = @import("aviutl2_sdk");
const L = std.unicode.utf8ToUtf16LeStringLiteral;

extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?*anyopaque) callconv(.winapi) usize;
extern "kernel32" fn WriteFile(file: usize, buffer: [*]const u8, length: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn CloseHandle(handle: usize) callconv(.winapi) c_int;

fn logLine(text: []const u8) void {
    const file_append_data = 0x4;
    const open_always = 4;
    const file = CreateFileW(L("C:\\Users\\Public\\aviutl2_noop.log"), file_append_data, 0x1 | 0x2, null, open_always, 0x80, null);
    if (file == std.math.maxInt(usize)) return;
    defer _ = CloseHandle(file);
    var written: u32 = 0;
    _ = WriteFile(file, text.ptr, @intCast(text.len), &written, null);
    _ = WriteFile(file, "\r\n", 2, &written, null);
}

var logged_proc = false;
fn procVideo(_: *plugin.VideoProc) callconv(.c) bool {
    if (!logged_proc) {
        logged_proc = true;
        logLine("[zig] proc_video called");
    }
    return true;
}

var dummy = plugin.TrackItem{ .name = L("Dummy").ptr, .value = 0, .start = 0, .end = 100, .step = 1, .zero_display = null, .slider_ratio = 1 };
var items = [_]?*anyopaque{ @ptrCast(&dummy), null };
var table = plugin.FilterTable{
    .flag = 1 | 8,
    .name = L("Noop filter (Zig)").ptr,
    .label = L("Debug").ptr,
    .information = L("Do-nothing filter for plugin loading tests").ptr,
    .items = &items,
    .proc_video = procVideo,
    .proc_audio = null,
};

pub fn DllMain(_: std.os.windows.HINSTANCE, reason: std.os.windows.DWORD, _: std.os.windows.LPVOID) callconv(.winapi) std.os.windows.BOOL {
    if (reason == 1) logLine("[zig] DllMain: loaded");
    return .TRUE;
}

pub export fn InitializePlugin(version: u32) callconv(.c) bool {
    var buffer: [64]u8 = undefined;
    logLine(std.fmt.bufPrint(&buffer, "[zig] InitializePlugin(version={d})", .{version}) catch "[zig] InitializePlugin");
    return true;
}

pub export fn UninitializePlugin() callconv(.c) void {
    logLine("[zig] UninitializePlugin");
}

pub export fn GetFilterPluginTable() callconv(.c) *plugin.FilterTable {
    logLine("[zig] GetFilterPluginTable");
    return &table;
}
