//! Loads AviUtl's lua51.dll, requires Simple_LUT.dll from Lua as the .anm script does, and
//! checks Simple_LUT.LUT against lut_math run in-process.
//! Usage: legacy_harness.exe <lua51.dll> <directory containing Simple_LUT.dll> <lut file>
const std = @import("std");
const plugin = @import("legacy");
const lut_math = plugin.lut_math;
const win32 = plugin.win32;
const Pixel = plugin.Pixel;

const State = opaque {};
const globals_index = -10002;
extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

const Lua = struct {
    newstate: *const fn () callconv(.c) ?*State,
    openlibs: *const fn (*State) callconv(.c) void,
    loadstring: *const fn (*State, [*:0]const u8) callconv(.c) c_int,
    pcall: *const fn (*State, c_int, c_int, c_int) callconv(.c) c_int,
    tolstring: *const fn (*State, c_int, ?*usize) callconv(.c) ?[*:0]const u8,
    newuserdata: *const fn (*State, usize) callconv(.c) ?*anyopaque,
    pushlstring: *const fn (*State, [*]const u8, usize) callconv(.c) void,
    setfield: *const fn (*State, c_int, [*:0]const u8) callconv(.c) void,
    close: *const fn (*State) callconv(.c) void,
};

const width = 320;
const height = 240;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 4) return error.Usage;
    const module = LoadLibraryW(try std.unicode.wtf8ToWtf16LeAllocZ(allocator, args[1])) orelse return error.LoadLibraryFailed;
    var lua: Lua = undefined;
    inline for (@typeInfo(Lua).@"struct".fields) |field| {
        const name = if (comptime std.mem.eql(u8, field.name, "newstate") or std.mem.eql(u8, field.name, "openlibs") or std.mem.eql(u8, field.name, "loadstring")) "luaL_" ++ field.name else "lua_" ++ field.name;
        @field(lua, field.name) = @ptrCast(GetProcAddress(module, name) orelse return error.MissingExport);
    }

    // Lua strings are in the ANSI code page, as in AviUtl. Skip when it cannot spell the path.
    const wide_lut = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, args[3]);
    const ansi_lut = try toAnsi(allocator, wide_lut) orelse {
        std.debug.print("skip: LUT path is not representable in the ANSI code page\n", .{});
        return;
    };
    const ansi_dir = try toAnsi(allocator, try std.unicode.wtf8ToWtf16LeAllocZ(allocator, args[2])) orelse {
        std.debug.print("skip: plugin directory is not representable in the ANSI code page\n", .{});
        return;
    };

    const bytes = try win32.readFile(wide_lut.ptr);
    var lut = try lut_math.parse(allocator, bytes, lut_math.formatFromPath(u16, wide_lut).?);
    defer lut.deinit(allocator);

    const L = lua.newstate() orelse return error.LuaFailed;
    defer lua.close(L);
    lua.openlibs(L);
    lua.pushlstring(L, ansi_lut.ptr, ansi_lut.len);
    lua.setfield(L, globals_index, "lut_path");
    lua.pushlstring(L, ansi_dir.ptr, ansi_dir.len);
    lua.setfield(L, globals_index, "dll_dir");
    try run(&lua, L, "package.cpath = dll_dir .. '\\\\?.dll;' .. package.cpath; require('Simple_LUT')");
    try run(&lua, L, "assert(type(Simple_LUT.getDir()) == 'string', 'getDir')");
    try run(&lua, L, "local ok, err = Simple_LUT.LUT(nil, 1, 1, 1, 2, lut_path); assert(ok == nil and type(err) == 'string', 'nil data accepted')");

    var frame: [width * height]Pixel = undefined;
    for (&frame, 0..) |*pixel, index| {
        const x = index % width;
        const y = index / width;
        pixel.* = .{ .r = @intCast(x * 255 / (width - 1)), .g = @intCast(y * 255 / (height - 1)), .b = @intCast((x + y) % 256), .a = if (x == 7) 0 else 255 };
    }
    for ([_]lut_math.Mode{ .nearest, .tetrahedral, .trilinear }) |mode| {
        for ([_]f32{ 1.0, 0.8 }) |amount| {
            const data: *[width * height]Pixel = @ptrCast(@alignCast(lua.newuserdata(L, @sizeOf(@TypeOf(frame))) orelse return error.LuaFailed));
            data.* = frame;
            lua.setfield(L, globals_index, "data");
            const script = try std.fmt.allocPrintSentinel(allocator, "local ok, err = Simple_LUT.LUT(data, {d}, {d}, {d}, {d}, lut_path); assert(ok, err)", .{ width, height, amount, @intFromEnum(mode) }, 0);
            try run(&lua, L, script);
            var expected = frame;
            lut_math.processPixels(Pixel, &expected, width, height, &lut, mode, amount);
            if (!std.mem.eql(u8, std.mem.asBytes(&expected), std.mem.asBytes(data))) return error.OutputMismatch;
            std.debug.print("ok  {s} strength {d}\n", .{ @tagName(mode), amount });
        }
    }
    try run(&lua, L, "local ok, err = Simple_LUT.LUT(data, 1, 1, 1, 2, 'does-not-exist.cube'); assert(ok == nil and err == 'FileNotFound', tostring(err))");
    std.debug.print("ok  missing file rejected\n", .{});
}

fn run(lua: *const Lua, L: *State, script: [*:0]const u8) !void {
    if (lua.loadstring(L, script) != 0 or lua.pcall(L, 0, 0, 0) != 0) {
        std.debug.print("lua error: {s}\n", .{lua.tolstring(L, -1, null) orelse "?"});
        return error.LuaError;
    }
}

fn toAnsi(allocator: std.mem.Allocator, wide: [:0]const u16) !?[]u8 {
    var lossy: c_int = 0;
    const length = win32.WideCharToMultiByte(win32.cp_acp, 0, wide.ptr, @intCast(wide.len), null, 0, null, &lossy);
    if (length <= 0 or lossy != 0) return null;
    const text = try allocator.alloc(u8, @intCast(length));
    _ = win32.WideCharToMultiByte(win32.cp_acp, 0, wide.ptr, @intCast(wide.len), text.ptr, length, null, null);
    return text;
}
