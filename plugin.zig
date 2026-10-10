const std = @import("std");
pub const lut_math = @import("lut_math.zig");
pub const win32 = @import("win32.zig");

/// AviUtl's obj.getpixeldata() buffer layout.
pub const Pixel = extern struct { b: u8, g: u8, r: u8, a: u8 };
const LuaState = opaque {};
const LuaFunction = *const fn (*LuaState) callconv(.c) c_int;
const LuaReg = extern struct { name: ?[*:0]const u8, func: ?LuaFunction };

const Lua = struct {
    to_integer: *const fn (*LuaState, c_int) callconv(.c) isize,
    to_number: *const fn (*LuaState, c_int) callconv(.c) f64,
    to_string: *const fn (*LuaState, c_int, ?*usize) callconv(.c) ?[*]const u8,
    to_userdata: *const fn (*LuaState, c_int) callconv(.c) ?*anyopaque,
    push_nil: *const fn (*LuaState) callconv(.c) void,
    push_boolean: *const fn (*LuaState, c_int) callconv(.c) void,
    push_string: *const fn (*LuaState, [*:0]const u8) callconv(.c) void,
    push_lstring: *const fn (*LuaState, [*]const u8, usize) callconv(.c) void,
    register: *const fn (*LuaState, [*:0]const u8, [*]const LuaReg) callconv(.c) void,
};

extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

/// Resolved once in luaopen_Simple_LUT, which Lua always calls before any library function.
var api: Lua = undefined;
var cache: win32.SharedCache = .{};

fn proc(module: *anyopaque, name: [*:0]const u8, comptime T: type) ?T {
    const address = GetProcAddress(module, name) orelse return null;
    return @ptrCast(address);
}

fn loadLuaApi() ?Lua {
    const module = GetModuleHandleA("lua51.dll") orelse LoadLibraryA("lua51.dll") orelse return null;
    return .{
        .to_integer = proc(module, "lua_tointeger", @FieldType(Lua, "to_integer")) orelse return null,
        .to_number = proc(module, "lua_tonumber", @FieldType(Lua, "to_number")) orelse return null,
        .to_string = proc(module, "lua_tolstring", @FieldType(Lua, "to_string")) orelse return null,
        .to_userdata = proc(module, "lua_touserdata", @FieldType(Lua, "to_userdata")) orelse return null,
        .push_nil = proc(module, "lua_pushnil", @FieldType(Lua, "push_nil")) orelse return null,
        .push_boolean = proc(module, "lua_pushboolean", @FieldType(Lua, "push_boolean")) orelse return null,
        .push_string = proc(module, "lua_pushstring", @FieldType(Lua, "push_string")) orelse return null,
        .push_lstring = proc(module, "lua_pushlstring", @FieldType(Lua, "push_lstring")) orelse return null,
        .register = proc(module, "luaL_register", @FieldType(Lua, "register")) orelse return null,
    };
}

fn fail(L: *LuaState, message: [*:0]const u8) c_int {
    api.push_nil(L);
    api.push_string(L, message);
    return 2;
}

/// Simple_LUT.LUT(data, width, height, strength, mode, path) -> true | nil, error
/// `path` is in the ANSI code page, as AviUtl passes it. Parsed LUTs are cached in the DLL
/// and reloaded when the file changes on disk.
fn lut(L: *LuaState) callconv(.c) c_int {
    const pixels: [*]Pixel = @ptrCast(@alignCast(api.to_userdata(L, 1) orelse return fail(L, "pixel data expected")));
    const width = api.to_integer(L, 2);
    const height = api.to_integer(L, 3);
    const strength: f32 = @floatCast(api.to_number(L, 4));
    const mode = lut_math.Mode.fromInt(api.to_integer(L, 5)) orelse return fail(L, "unknown interpolation type");
    var path_length: usize = 0;
    const path = api.to_string(L, 6, &path_length) orelse return fail(L, "LUT path expected");
    if (width <= 0 or height <= 0) return fail(L, "invalid image size");
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);

    const wide_path = win32.toWide(win32.cp_acp, path[0..path_length]) catch return fail(L, "invalid LUT path");
    defer win32.allocator.free(wide_path);
    const table = cache.acquire(wide_path) catch |err| return fail(L, @errorName(err));
    defer cache.release();
    lut_math.processPixels(Pixel, pixels[0 .. w * h], w, h, table, mode, strength);
    api.push_boolean(L, 1);
    return 1;
}

/// Simple_LUT.getDir() -> AviUtl's install directory (from the executable path, not the
/// current directory, which file dialogs change).
fn getDir(L: *LuaState) callconv(.c) c_int {
    var wide: [32768]u16 = undefined;
    const length = win32.GetModuleFileNameW(null, &wide, wide.len);
    if (length == 0 or length >= wide.len) return fail(L, "GetModuleFileNameW failed");
    const directory = std.mem.lastIndexOfScalar(u16, wide[0..length], '\\') orelse return fail(L, "unexpected module path");
    var text: [32768 * 2]u8 = undefined;
    const bytes = win32.WideCharToMultiByte(win32.cp_acp, 0, &wide, @intCast(directory), &text, text.len, null, null);
    if (bytes <= 0) return fail(L, "WideCharToMultiByte failed");
    api.push_lstring(L, &text, @intCast(bytes));
    return 1;
}

const functions = [_]LuaReg{
    .{ .name = "LUT", .func = lut },
    .{ .name = "getDir", .func = getDir },
    .{ .name = null, .func = null },
};

pub export fn luaopen_Simple_LUT(L: *LuaState) callconv(.c) c_int {
    api = loadLuaApi() orelse return 0;
    api.register(L, "Simple_LUT", &functions);
    return 1;
}
