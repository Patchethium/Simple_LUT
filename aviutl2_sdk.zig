//! Hand-written mirrors of the AviUtl2 SDK structs (filter2.h) that the filters use, checked
//! against aviutl2_layout.zig at compile time.
const std = @import("std");
const layout = @import("aviutl2_layout.zig");
const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const Pixel = extern struct { r: u8, g: u8, b: u8, a: u8 };
pub const ObjectInfo = extern struct {
    id: i64,
    frame: c_int,
    frame_total: c_int,
    time: f64,
    time_total: f64,
    width: c_int,
    height: c_int,
};
pub const VideoProc = extern struct {
    scene: ?*const anyopaque,
    object: *const ObjectInfo,
    get_image_data: *const fn ([*]Pixel) callconv(.c) void,
    set_image_data: *const fn ([*]const Pixel, c_int, c_int) callconv(.c) void,
};
pub const TrackItem = extern struct {
    type_name: [*:0]const u16 = L("track2").ptr,
    name: [*:0]const u16,
    value: f64,
    start: f64,
    end: f64,
    step: f64,
    zero_display: ?[*:0]const u16,
    slider_ratio: f64,
};
pub const SelectOption = extern struct { name: ?[*:0]const u16, value: c_int };
pub const SelectItem = extern struct {
    type_name: [*:0]const u16 = L("select").ptr,
    name: [*:0]const u16,
    value: c_int,
    options: [*]const SelectOption,
};
pub const FileItem = extern struct {
    type_name: [*:0]const u16 = L("file").ptr,
    name: [*:0]const u16,
    value: [*:0]const u16,
    filter: [*:0]const u16,
};
pub const FilterTable = extern struct {
    flag: c_int,
    name: [*:0]const u16,
    label: [*:0]const u16,
    information: [*:0]const u16,
    items: [*]?*anyopaque,
    proc_video: *const fn (*VideoProc) callconv(.c) bool,
    proc_audio: ?*const anyopaque,
};

// The structs above are hand-written mirrors of filter2.h; a layout change in the SDK must
// break the build rather than corrupt memory. Only the fields the filters touch are checked
// for structs the host owns (ObjectInfo, VideoProc), whose tails keep growing.
comptime {
    if (@import("builtin").cpu.arch == .x86_64) {
        assertOffset(ObjectInfo, "frame", layout.OBJECT_INFO_frame);
        assertOffset(ObjectInfo, "time", layout.OBJECT_INFO_time);
        assertOffset(ObjectInfo, "width", layout.OBJECT_INFO_width);
        assertOffset(ObjectInfo, "height", layout.OBJECT_INFO_height);
        assertOffset(VideoProc, "scene", layout.FILTER_PROC_VIDEO_scene);
        assertOffset(VideoProc, "object", layout.FILTER_PROC_VIDEO_object);
        assertOffset(VideoProc, "get_image_data", layout.FILTER_PROC_VIDEO_get_image_data);
        assertOffset(VideoProc, "set_image_data", layout.FILTER_PROC_VIDEO_set_image_data);
        assertSize(Pixel, layout.PIXEL_RGBA_size);
        assertSize(TrackItem, layout.FILTER_ITEM_TRACK_size);
        assertOffset(TrackItem, "value", layout.FILTER_ITEM_TRACK_value);
        assertOffset(TrackItem, "zero_display", layout.FILTER_ITEM_TRACK_zero_display);
        assertOffset(TrackItem, "slider_ratio", layout.FILTER_ITEM_TRACK_slider_ratio);
        assertSize(SelectItem, layout.FILTER_ITEM_SELECT_size);
        assertOffset(SelectItem, "value", layout.FILTER_ITEM_SELECT_value);
        assertOffset(SelectItem, "options", layout.FILTER_ITEM_SELECT_list);
        assertSize(SelectOption, layout.FILTER_ITEM_SELECT_ITEM_size);
        assertSize(FileItem, layout.FILTER_ITEM_FILE_size);
        assertOffset(FileItem, "value", layout.FILTER_ITEM_FILE_value);
        assertOffset(FileItem, "filter", layout.FILTER_ITEM_FILE_filefilter);
        assertSize(FilterTable, layout.FILTER_PLUGIN_TABLE_size);
        assertOffset(FilterTable, "items", layout.FILTER_PLUGIN_TABLE_items);
        assertOffset(FilterTable, "proc_video", layout.FILTER_PLUGIN_TABLE_func_proc_video);
        assertOffset(FilterTable, "proc_audio", layout.FILTER_PLUGIN_TABLE_func_proc_audio);
    }
}

fn assertSize(comptime T: type, comptime expected: usize) void {
    if (@sizeOf(T) != expected) @compileError(std.fmt.comptimePrint("{s} is {d} bytes; the SDK says {d}", .{ @typeName(T), @sizeOf(T), expected }));
}

fn assertOffset(comptime T: type, comptime field: []const u8, comptime expected: usize) void {
    if (@offsetOf(T, field) != expected) @compileError(std.fmt.comptimePrint("{s}.{s} is at {d}; the SDK says {d}", .{ @typeName(T), field, @offsetOf(T, field), expected }));
}
