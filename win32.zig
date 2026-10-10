//! Windows glue shared by the AviUtl plugins: wide-path file access and a locked LUT cache.
const std = @import("std");
const lut_math = @import("lut_math.zig");
const lut_cache = @import("lut_cache.zig");

pub const allocator = std.heap.c_allocator;

const Handle = *anyopaque;
const invalid_handle: usize = std.math.maxInt(usize);
const generic_read = 0x8000_0000;
const file_share_read = 0x1;
const file_share_write = 0x2;
const open_existing = 3;
const file_attribute_normal = 0x80;
pub const cp_acp = 0;

const FileTime = extern struct { low: u32, high: u32 };
const FileAttributeData = extern struct {
    attributes: u32,
    creation: FileTime,
    last_access: FileTime,
    last_write: FileTime,
    size_high: u32,
    size_low: u32,
};
const SrwLock = extern struct { ptr: ?*anyopaque = null };

extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?Handle) callconv(.winapi) usize;
extern "kernel32" fn GetFileSizeEx(file: Handle, size: *i64) callconv(.winapi) c_int;
extern "kernel32" fn ReadFile(file: Handle, buffer: [*]u8, length: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) c_int;
extern "kernel32" fn GetFileAttributesExW(name: [*:0]const u16, level: c_int, data: *FileAttributeData) callconv(.winapi) c_int;
extern "kernel32" fn AcquireSRWLockExclusive(lock: *SrwLock) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SrwLock) callconv(.winapi) void;
extern "kernel32" fn MultiByteToWideChar(code_page: u32, flags: u32, text: [*]const u8, length: c_int, wide: ?[*]u16, wide_length: c_int) callconv(.winapi) c_int;
pub extern "kernel32" fn WideCharToMultiByte(code_page: u32, flags: u32, wide: [*]const u16, wide_length: c_int, text: ?[*]u8, length: c_int, default_char: ?*const u8, used_default: ?*c_int) callconv(.winapi) c_int;
pub extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, name: [*]u16, length: u32) callconv(.winapi) u32;

pub fn readFile(path: [*:0]const u16) ![]u8 {
    const raw = CreateFileW(path, generic_read, file_share_read | file_share_write, null, open_existing, file_attribute_normal, null);
    if (raw == invalid_handle) return error.FileNotFound;
    const file: Handle = @ptrFromInt(raw);
    defer _ = CloseHandle(file);
    var size: i64 = 0;
    if (GetFileSizeEx(file, &size) == 0) return error.FileReadFailed;
    if (size < 0 or size > lut_math.max_file_bytes) return error.FileTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(bytes);
    var filled: usize = 0;
    while (filled < bytes.len) {
        var read: u32 = 0;
        if (ReadFile(file, bytes.ptr + filled, @intCast(bytes.len - filled), &read, null) == 0 or read == 0) return error.FileReadFailed;
        filled += read;
    }
    return bytes;
}

/// Last-write time plus size, so edits to the LUT on disk invalidate the cache. Zero when unknown.
pub fn fileStamp(path: [*:0]const u16) u64 {
    var data: FileAttributeData = undefined;
    if (GetFileAttributesExW(path, 0, &data) == 0) return 0;
    const time = (@as(u64, data.last_write.high) << 32) | data.last_write.low;
    return time ^ (@as(u64, data.size_low) << 1);
}

/// Converts text in `code_page` to a NUL-terminated UTF-16 string owned by `allocator`.
pub fn toWide(code_page: u32, text: []const u8) ![:0]u16 {
    if (text.len == 0) return error.InvalidPath;
    const length = MultiByteToWideChar(code_page, 0, text.ptr, @intCast(text.len), null, 0);
    if (length <= 0) return error.InvalidPath;
    const wide = try allocator.allocSentinel(u16, @intCast(length), 0);
    errdefer allocator.free(wide);
    if (MultiByteToWideChar(code_page, 0, text.ptr, @intCast(text.len), wide.ptr, length) != length) return error.InvalidPath;
    return wide;
}

const Loader = struct {
    pub fn load(_: Loader, gpa: std.mem.Allocator, path: []const u16) !lut_math.Lut {
        const format = lut_math.formatFromPath(u16, path) orelse return error.UnsupportedFormat;
        const path_z = try gpa.dupeZ(u16, path);
        defer gpa.free(path_z);
        const bytes = try readFile(path_z.ptr);
        defer allocator.free(bytes);
        return lut_math.parse(gpa, bytes, format);
    }
};

/// Process-wide LUT cache. `acquire` returns with the lock held; call `release` once the
/// returned LUT is no longer used.
pub const SharedCache = struct {
    lock: SrwLock = .{},
    cache: lut_cache.Cache(u16, 4) = .{},

    pub fn acquire(self: *SharedCache, path: [:0]const u16) !*const lut_math.Lut {
        AcquireSRWLockExclusive(&self.lock);
        errdefer ReleaseSRWLockExclusive(&self.lock);
        return self.cache.get(allocator, path, fileStamp(path.ptr), Loader{});
    }

    pub fn release(self: *SharedCache) void {
        ReleaseSRWLockExclusive(&self.lock);
    }

    pub fn deinit(self: *SharedCache) void {
        AcquireSRWLockExclusive(&self.lock);
        defer ReleaseSRWLockExclusive(&self.lock);
        self.cache.deinit(allocator);
    }
};
