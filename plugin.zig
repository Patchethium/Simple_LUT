const std = @import("std");
const lut_math = @import("lut_math.zig");

const Rgb = lut_math.Rgb;
const Lut = lut_math.Lut;
const PixelRgba = extern struct { b: u8, g: u8, r: u8, a: u8 };
const max_workers = 8;
const LuaState = opaque {};
const LuaFunction = *const fn (*LuaState) callconv(.c) c_int;
const LuaReg = extern struct { name: ?[*:0]const u8, func: ?LuaFunction };

const Lua = struct {
    to_integer: *const fn (*LuaState, c_int) callconv(.c) isize,
    to_number: *const fn (*LuaState, c_int) callconv(.c) f64,
    to_boolean: *const fn (*LuaState, c_int) callconv(.c) c_int,
    to_string: *const fn (*LuaState, c_int, ?*usize) callconv(.c) ?[*:0]const u8,
    to_userdata: *const fn (*LuaState, c_int) callconv(.c) ?*anyopaque,
    new_userdata: *const fn (*LuaState, usize) callconv(.c) ?*anyopaque,
    push_integer: *const fn (*LuaState, isize) callconv(.c) void,
    push_string: *const fn (*LuaState, [*:0]const u8) callconv(.c) void,
    register: *const fn (*LuaState, [*:0]const u8, [*]const LuaReg) callconv(.c) void,
};

extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn GetCurrentDirectoryA(length: u32, buffer: [*]u8) callconv(.winapi) u32;

fn proc(module: *anyopaque, name: [*:0]const u8, comptime T: type) ?T {
    const address = GetProcAddress(module, name) orelse return null;
    return @ptrCast(address);
}

fn luaApi() ?Lua {
    const module = GetModuleHandleA("lua51.dll") orelse LoadLibraryA("lua51.dll") orelse return null;
    return .{
        .to_integer = proc(module, "lua_tointeger", @FieldType(Lua, "to_integer")) orelse return null,
        .to_number = proc(module, "lua_tonumber", @FieldType(Lua, "to_number")) orelse return null,
        .to_boolean = proc(module, "lua_toboolean", @FieldType(Lua, "to_boolean")) orelse return null,
        .to_string = proc(module, "lua_tolstring", @FieldType(Lua, "to_string")) orelse return null,
        .to_userdata = proc(module, "lua_touserdata", @FieldType(Lua, "to_userdata")) orelse return null,
        .new_userdata = proc(module, "lua_newuserdata", @FieldType(Lua, "new_userdata")) orelse return null,
        .push_integer = proc(module, "lua_pushinteger", @FieldType(Lua, "push_integer")) orelse return null,
        .push_string = proc(module, "lua_pushstring", @FieldType(Lua, "push_string")) orelse return null,
        .register = proc(module, "luaL_register", @FieldType(Lua, "register")) orelse return null,
    };
}

fn at(context: *const Lut, r: usize, g: usize, b: usize) Rgb {
    return context.values[r][g][b];
}

fn lut(L: *LuaState) callconv(.c) c_int {
    const api = luaApi() orelse return 0;
    const width: usize = @intCast(api.to_integer(L, 2));
    const height: usize = @intCast(api.to_integer(L, 3));
    const strength: f32 = @floatCast(api.to_number(L, 4));
    const interpolation = api.to_integer(L, 5);
    const extension = api.to_integer(L, 6);
    const path = api.to_string(L, 7, null) orelse return 0;
    const cached = api.to_boolean(L, 9) != 0;
    if (extension < 2 or extension > 4) return 0;

    const context: *Lut = if (cached)
        @ptrCast(@alignCast(api.to_userdata(L, 10) orelse return 2))
    else
        lut_math.loadLut(path) orelse return 0;
    defer if (!cached) std.heap.c_allocator.destroy(context);
    if (context.size == 0) return 2;

    const pixels: [*]PixelRgba = @ptrCast(@alignCast(api.to_userdata(L, 1) orelse return 0));
    processPixels(pixels, width, height, context, interpolation, strength);

    if (cached) return 0;
    const storage = api.new_userdata(L, @sizeOf(Lut)) orelse return 0;
    @memcpy(@as([*]u8, @ptrCast(storage))[0..@sizeOf(Lut)], std.mem.asBytes(context));
    api.push_integer(L, @sizeOf(Lut));
    return 2;
}

const Work = struct {
    pixels: [*]PixelRgba,
    start_row: usize,
    end_row: usize,
    width: usize,
    context: *const Lut,
    interpolation: isize,
    strength: f32,
};

fn processPixels(pixels: [*]PixelRgba, width: usize, height: usize, context: *const Lut, interpolation: isize, strength: f32) void {
    const worker_count = @min(@min(std.Thread.getCpuCount() catch 1, max_workers), height);
    if (worker_count < 2 or width * height < 65_536) {
        const single_worker = Work{
            .pixels = pixels,
            .start_row = 0,
            .end_row = height,
            .width = width,
            .context = context,
            .interpolation = interpolation,
            .strength = strength,
        };
        processRows(&single_worker);
        return;
    }

    var workers: [max_workers]Work = undefined;
    var threads: [max_workers - 1]std.Thread = undefined;
    var spawned: [max_workers - 1]bool = [_]bool{false} ** (max_workers - 1);
    var worker_index: usize = 0;
    while (worker_index < worker_count) : (worker_index += 1) {
        workers[worker_index] = .{
            .pixels = pixels,
            .start_row = height * worker_index / worker_count,
            .end_row = height * (worker_index + 1) / worker_count,
            .width = width,
            .context = context,
            .interpolation = interpolation,
            .strength = strength,
        };
    }
    worker_index = 1;
    while (worker_index < worker_count) : (worker_index += 1) {
        threads[worker_index - 1] = std.Thread.spawn(.{}, processRows, .{&workers[worker_index]}) catch {
            processRows(&workers[worker_index]);
            continue;
        };
        spawned[worker_index - 1] = true;
    }
    processRows(&workers[0]);
    worker_index = 1;
    while (worker_index < worker_count) : (worker_index += 1) {
        if (spawned[worker_index - 1]) threads[worker_index - 1].join();
    }
}

fn processRows(work: *const Work) void {
    for (work.start_row * work.width .. work.end_row * work.width) |index| {
        const pixel = &work.pixels[index];
        if (pixel.a == 0) continue;
        const input = Rgb{ .r = @floatFromInt(pixel.r), .g = @floatFromInt(pixel.g), .b = @floatFromInt(pixel.b) };
        if (work.interpolation < 1 or work.interpolation > 3) continue;
        const output = lut_math.interpolate(Lut, work.context, input, @intCast(work.interpolation), at);
        pixel.r = blend(lut_math.toByte(output.r), pixel.r, work.strength);
        pixel.g = blend(lut_math.toByte(output.g), pixel.g, work.strength);
        pixel.b = blend(lut_math.toByte(output.b), pixel.b, work.strength);
    }
}

fn blend(output: u8, input: u8, strength: f32) u8 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(output)) * strength + @as(f32, @floatFromInt(input)) * (1 - strength)));
}

fn getBuffer(L: *LuaState) callconv(.c) c_int {
    const api = luaApi() orelse return 0;
    const size: usize = @intCast(api.to_integer(L, 1));
    _ = api.new_userdata(L, size) orelse return 0;
    return 1;
}

fn getDir(L: *LuaState) callconv(.c) c_int {
    const api = luaApi() orelse return 0;
    var path: [260]u8 = undefined;
    const length = GetCurrentDirectoryA(path.len, &path);
    if (length == 0 or length >= path.len) return 0;
    path[length] = 0;
    api.push_string(L, path[0..length :0].ptr);
    return 1;
}

const functions = [_]LuaReg{
    .{ .name = "LUT", .func = lut },
    .{ .name = "getBuffer", .func = getBuffer },
    .{ .name = "getDir", .func = getDir },
    .{ .name = null, .func = null },
};

pub export fn luaopen_Simple_LUT(L: *LuaState) callconv(.c) c_int {
    const api = luaApi() orelse return 0;
    api.register(L, "Simple_LUT", &functions);
    api.register(L, "getBuffer", &functions);
    api.register(L, "getDir", &functions);
    return 3;
}
