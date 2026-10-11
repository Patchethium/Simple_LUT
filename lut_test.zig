const std = @import("std");
const lut_math = @import("lut_math.zig");
const lut_cache = @import("lut_cache.zig");
const testing = std.testing;
const Lut = lut_math.Lut;
const Mode = lut_math.Mode;

const Rgba = extern struct { r: u8, g: u8, b: u8, a: u8 };
const Bgra = extern struct { b: u8, g: u8, r: u8, a: u8 };
const modes = [_]Mode{ .nearest, .tetrahedral, .trilinear };

fn identityCube(allocator: std.mem.Allocator, size: usize, header: []const u8) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    try text.print(allocator, "TITLE \"identity\"\n# comment\n{s}LUT_3D_SIZE {d}\n", .{ header, size });
    const last: f64 = @floatFromInt(size - 1);
    for (0..size) |b| for (0..size) |g| for (0..size) |r| {
        try text.print(allocator, "{d:.6} {d:.6} {d:.6}\n", .{ @as(f64, @floatFromInt(r)) / last, @as(f64, @floatFromInt(g)) / last, @as(f64, @floatFromInt(b)) / last });
    };
    return text.toOwnedSlice(allocator);
}

fn identity3dl(allocator: std.mem.Allocator, size: usize, bits: u5, shaper: bool) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    const top: usize = (@as(usize, 1) << bits) - 1;
    if (shaper) {
        for (0..size) |index| try text.print(allocator, "{d} ", .{index * 1023 / (size - 1)});
        try text.append(allocator, '\n');
    }
    for (0..size) |r| for (0..size) |g| for (0..size) |b| {
        try text.print(allocator, "{d} {d} {d}\n", .{ (r * top + (size - 1) / 2) / (size - 1), (g * top + (size - 1) / 2) / (size - 1), (b * top + (size - 1) / 2) / (size - 1) });
    };
    return text.toOwnedSlice(allocator);
}

fn identityM3d(allocator: std.mem.Allocator, size: usize, order: []const u8) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    try text.print(allocator, "# m3d\nin {d}\nout 256\nvalues {s}\n", .{ size * size * size, order });
    for (0..size) |r| for (0..size) |g| for (0..size) |b| {
        const channels = [3]usize{ r * 255 / (size - 1), g * 255 / (size - 1), b * 255 / (size - 1) };
        var columns: [3]usize = undefined;
        var names = std.mem.tokenizeScalar(u8, order, ' ');
        var position: usize = 0;
        while (names.next()) |name| : (position += 1) columns[position] = channels[
            switch (name[0]) {
                'r' => @as(usize, 0),
                'g' => 1,
                else => 2,
            }
        ];
        try text.print(allocator, "{d} {d} {d}\n", .{ columns[0], columns[1], columns[2] });
    };
    return text.toOwnedSlice(allocator);
}

fn parseText(text: []const u8, format: lut_math.Format) !Lut {
    return lut_math.parse(testing.allocator, text, format);
}

/// Every 8-bit value on each channel plus random triples must come back within 1 LSB.
fn expectIdentity(lut: *const Lut) !void {
    var pixels: [256 + 2048]Rgba = undefined;
    for (pixels[0..256], 0..) |*pixel, value| {
        const v: u8 = @intCast(value);
        pixel.* = .{ .r = v, .g = 255 - v, .b = v / 2 +% 64, .a = 255 };
    }
    var prng = std.Random.DefaultPrng.init(0x5eed);
    for (pixels[256..]) |*pixel| pixel.* = .{ .r = prng.random().int(u8), .g = prng.random().int(u8), .b = prng.random().int(u8), .a = 255 };
    for (modes) |mode| {
        var output = pixels;
        lut_math.processPixels(Rgba, &output, output.len, 1, lut, mode, 1);
        for (pixels, output) |before, after| {
            try expectNear(before.r, after.r, tolerance(mode, lut.size));
            try expectNear(before.g, after.g, tolerance(mode, lut.size));
            try expectNear(before.b, after.b, tolerance(mode, lut.size));
        }
    }
}

/// Interpolating modes are exact to 1 LSB; nearest may be off by half a lattice step.
fn tolerance(mode: Mode, size: usize) u8 {
    return if (mode == .nearest) @intCast(255 / (2 * (size - 1)) + 1) else 1;
}

fn expectNear(expected: u8, actual: u8, allowed: u8) !void {
    const difference = @max(expected, actual) - @min(expected, actual);
    if (difference > allowed) {
        std.debug.print("expected {d}, got {d}\n", .{ expected, actual });
        return error.TestExpectedApproxEq;
    }
}

test "identity .cube of common sizes reproduces input" {
    for ([_]usize{ 2, 17, 33, 65 }) |size| {
        const text = try identityCube(testing.allocator, size, "");
        defer testing.allocator.free(text);
        var lut = try parseText(text, .cube);
        defer lut.deinit(testing.allocator);
        try testing.expectEqual(size, lut.size);
        try expectIdentity(&lut);
    }
}

test "identity .3dl with shaper line, mesh header, and several bit depths" {
    for ([_]usize{ 17, 33 }) |size| {
        for ([_]u5{ 10, 12, 16 }) |bits| {
            const text = try identity3dl(testing.allocator, size, bits, true);
            defer testing.allocator.free(text);
            var lut = try parseText(text, .@"3dl");
            defer lut.deinit(testing.allocator);
            try testing.expectEqual(size, lut.size);
            try expectIdentity(&lut);
        }
    }
    // No shaper line: size comes from the entry count.
    const bare = try identity3dl(testing.allocator, 17, 12, false);
    defer testing.allocator.free(bare);
    var bare_lut = try parseText(bare, .@"3dl");
    defer bare_lut.deinit(testing.allocator);
    try expectIdentity(&bare_lut);
    // Autodesk "Mesh" header sets size and output depth explicitly.
    const body = try identity3dl(testing.allocator, 17, 12, false);
    defer testing.allocator.free(body);
    const meshed = try std.mem.concat(testing.allocator, u8, &.{ "3DMESH\nMesh 4 12\n", body });
    defer testing.allocator.free(meshed);
    var mesh_lut = try parseText(meshed, .@"3dl");
    defer mesh_lut.deinit(testing.allocator);
    try expectIdentity(&mesh_lut);
}

test "identity .m3d honours the values column order" {
    for ([_][]const u8{ "red green blue", "blue green red", "green blue red" }) |order| {
        const text = try identityM3d(testing.allocator, 17, order);
        defer testing.allocator.free(text);
        var lut = try parseText(text, .m3d);
        defer lut.deinit(testing.allocator);
        try expectIdentity(&lut);
    }
}

test "unknown keywords and LUT_3D_INPUT_RANGE are accepted" {
    const text = try identityCube(testing.allocator, 17, "LUT_3D_INPUT_RANGE 0.0 1.0\nVENDOR_THING 1 2 3\n");
    defer testing.allocator.free(text);
    var lut = try parseText(text, .cube);
    defer lut.deinit(testing.allocator);
    try expectIdentity(&lut);
}

test "DOMAIN remaps input, not output" {
    const text = try identityCube(testing.allocator, 33, "DOMAIN_MIN 0.1 0.2 0.3\nDOMAIN_MAX 0.9 0.8 0.7\n");
    defer testing.allocator.free(text);
    var lut = try parseText(text, .cube);
    defer lut.deinit(testing.allocator);
    const low = [3]f32{ 0.1, 0.2, 0.3 };
    const high = [3]f32{ 0.9, 0.8, 0.7 };
    for (modes) |mode| {
        for (0..256) |value| {
            const v: u8 = @intCast(value);
            var pixel = [1]Rgba{.{ .r = v, .g = v, .b = v, .a = 255 }};
            lut_math.processPixels(Rgba, &pixel, 1, 1, &lut, mode, 1);
            const results = [3]u8{ pixel[0].r, pixel[0].g, pixel[0].b };
            for (results, low, high) |actual, min, max| {
                const expected = lut_math.toByte((@as(f32, @floatFromInt(v)) / 255.0 - min) / (max - min));
                try expectNear(expected, actual, tolerance(mode, lut.size));
            }
        }
    }
}

test "malformed files return errors without leaking" {
    const cases = [_]struct { text: []const u8, format: lut_math.Format, err: anyerror }{
        .{ .text = "0 0 0\n", .format = .cube, .err = error.MissingSize },
        .{ .text = "TITLE \"x\"\n", .format = .cube, .err = error.MissingSize },
        .{ .text = "LUT_3D_SIZE 1\n0 0 0\n", .format = .cube, .err = error.InvalidSize },
        .{ .text = "LUT_3D_SIZE 300\n", .format = .cube, .err = error.InvalidSize },
        .{ .text = "LUT_3D_SIZE 2\nLUT_3D_SIZE 2\n", .format = .cube, .err = error.InvalidSize },
        .{ .text = "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n", .format = .cube, .err = error.IncompleteData },
        .{ .text = "LUT_3D_SIZE 2\n0 0 0\n1 0 x\n", .format = .cube, .err = error.BadData },
        .{ .text = "LUT_3D_SIZE 2\n0 0 0 0\n", .format = .cube, .err = error.BadData },
        .{ .text = "LUT_3D_SIZE 2\n0 0 0\n0 0 0\n0 0 0\n0 0 0\n0 0 0\n0 0 0\n0 0 0\n0 0 0\n0 0 0\n", .format = .cube, .err = error.TooMuchData },
        .{ .text = "DOMAIN_MIN 1 1 1\nDOMAIN_MAX 0 0 0\nLUT_3D_SIZE 2\n0 0 0\n0 0 0\n0 0 0\n0 0 0\n0 0 0\n0 0 0\n0 0 0\n0 0 0\n", .format = .cube, .err = error.InvalidDomain },
        .{ .text = "LUT_1D_SIZE 4\n0 0 0\n", .format = .cube, .err = error.UnsupportedFormat },
        .{ .text = "0 512 1023\n0 0 0\n", .format = .@"3dl", .err = error.IncompleteData },
        .{ .text = "0 0 0\n0 0 0\n0 0 0\n", .format = .@"3dl", .err = error.IncompleteData },
        .{ .text = "0 0 x\n", .format = .@"3dl", .err = error.BadData },
        .{ .text = "in 9\nout 256\n0 0 0\n", .format = .m3d, .err = error.InvalidSize },
        .{ .text = "in 8\nout 256\n0 0 0\n", .format = .m3d, .err = error.IncompleteData },
        .{ .text = "0 0 0\n", .format = .m3d, .err = error.MissingSize },
        .{ .text = "in 8\nout 256\nvalues red red blue\n", .format = .m3d, .err = error.BadData },
    };
    for (cases) |case| {
        try testing.expectError(case.err, parseText(case.text, case.format));
    }
}

test "format is chosen from the extension of narrow and wide paths" {
    try testing.expectEqual(lut_math.Format.cube, lut_math.formatFromPath(u8, "a/b.CUBE").?);
    try testing.expectEqual(lut_math.Format.@"3dl", lut_math.formatFromPath(u8, "x.3dl").?);
    try testing.expectEqual(lut_math.Format.m3d, lut_math.formatFromPath(u16, std.unicode.utf8ToUtf16LeStringLiteral("色/補正.m3d")).?);
    try testing.expectEqual(@as(?lut_math.Format, null), lut_math.formatFromPath(u8, "noextension"));
}

fn invertLut() !Lut {
    var lut = try Lut.init(testing.allocator, 2);
    for (0..2) |r| for (0..2) |g| for (0..2) |b| {
        lut.values[lut.index(r, g, b)] = .{ .r = @floatFromInt(1 - r), .g = @floatFromInt(1 - g), .b = @floatFromInt(1 - b) };
    };
    return lut;
}

test "processPixels: alpha, strength, and channel order" {
    var lut = try invertLut();
    defer lut.deinit(testing.allocator);

    var transparent = [1]Rgba{.{ .r = 10, .g = 20, .b = 30, .a = 0 }};
    lut_math.processPixels(Rgba, &transparent, 1, 1, &lut, .tetrahedral, 1);
    try testing.expectEqual(Rgba{ .r = 10, .g = 20, .b = 30, .a = 0 }, transparent[0]);

    var unchanged = [1]Rgba{.{ .r = 10, .g = 20, .b = 30, .a = 255 }};
    lut_math.processPixels(Rgba, &unchanged, 1, 1, &lut, .tetrahedral, 0);
    try testing.expectEqual(Rgba{ .r = 10, .g = 20, .b = 30, .a = 255 }, unchanged[0]);

    var inverted = [1]Rgba{.{ .r = 10, .g = 20, .b = 30, .a = 255 }};
    lut_math.processPixels(Rgba, &inverted, 1, 1, &lut, .trilinear, 1);
    try testing.expectEqual(Rgba{ .r = 245, .g = 235, .b = 225, .a = 255 }, inverted[0]);

    // Half strength of an interpolated inverting LUT lands on mid-grey for every input.
    for ([_]Mode{ .tetrahedral, .trilinear }) |mode| {
        var half = [1]Rgba{.{ .r = 0, .g = 77, .b = 255, .a = 128 }};
        lut_math.processPixels(Rgba, &half, 1, 1, &lut, mode, 0.5);
        try testing.expectEqual(Rgba{ .r = 128, .g = 128, .b = 128, .a = 128 }, half[0]);
    }

    var rgba = [1]Rgba{.{ .r = 1, .g = 100, .b = 200, .a = 255 }};
    var bgra = [1]Bgra{.{ .r = 1, .g = 100, .b = 200, .a = 255 }};
    lut_math.processPixels(Rgba, &rgba, 1, 1, &lut, .tetrahedral, 0.3);
    lut_math.processPixels(Bgra, &bgra, 1, 1, &lut, .tetrahedral, 0.3);
    try testing.expectEqual(rgba[0].r, bgra[0].r);
    try testing.expectEqual(rgba[0].g, bgra[0].g);
    try testing.expectEqual(rgba[0].b, bgra[0].b);
}

test "multithreaded output is identical to single-threaded" {
    const text = try identityCube(testing.allocator, 17, "");
    defer testing.allocator.free(text);
    var lut = try parseText(text, .cube);
    defer lut.deinit(testing.allocator);
    // Make the table non-trivial so interpolation differences would show.
    for (lut.values) |*value| value.* = .{ .r = value.g * value.g, .g = 1 - value.b, .b = (value.r + value.b) / 2 };

    const width = 512;
    const height = 512;
    const source = try testing.allocator.alloc(Rgba, width * height);
    defer testing.allocator.free(source);
    var prng = std.Random.DefaultPrng.init(42);
    for (source) |*pixel| pixel.* = .{ .r = prng.random().int(u8), .g = prng.random().int(u8), .b = prng.random().int(u8), .a = prng.random().int(u8) };
    const threaded = try testing.allocator.dupe(Rgba, source);
    defer testing.allocator.free(threaded);
    const serial = try testing.allocator.dupe(Rgba, source);
    defer testing.allocator.free(serial);

    for (modes) |mode| {
        @memcpy(threaded, source);
        @memcpy(serial, source);
        lut_math.processPixels(Rgba, threaded, width, height, &lut, mode, 0.75);
        // A single row is too small to split across threads.
        for (0..height) |row| lut_math.processPixels(Rgba, serial[row * width ..][0..width], width, 1, &lut, mode, 0.75);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(serial), std.mem.sliceAsBytes(threaded));
    }
}

const CountingLoader = struct {
    loads: usize = 0,
    fail: bool = false,

    pub fn load(self: *CountingLoader, allocator: std.mem.Allocator, path: []const u8) !Lut {
        if (self.fail) return error.BadData;
        self.loads += 1;
        const lut = try Lut.init(allocator, 2);
        @memset(lut.values, .{ .r = @floatFromInt(path.len), .g = 0, .b = 0 });
        return lut;
    }
};

test "cache hits, reloads on stamp change, and evicts least recently used" {
    var cache: lut_cache.Cache(u8, 2) = .{};
    defer cache.deinit(testing.allocator);
    var loader = CountingLoader{};

    const a = try cache.get(testing.allocator, "a", 1, &loader);
    try testing.expectEqual(@as(usize, 1), loader.loads);
    try testing.expectEqual(a, try cache.get(testing.allocator, "a", 1, &loader));
    try testing.expectEqual(@as(usize, 1), loader.loads);

    _ = try cache.get(testing.allocator, "a", 2, &loader);
    try testing.expectEqual(@as(usize, 2), loader.loads);

    _ = try cache.get(testing.allocator, "bb", 1, &loader);
    _ = try cache.get(testing.allocator, "a", 2, &loader);
    try testing.expectEqual(@as(usize, 3), loader.loads);
    // "bb" is now least recently used, so "ccc" replaces it and "a" stays cached.
    _ = try cache.get(testing.allocator, "ccc", 1, &loader);
    _ = try cache.get(testing.allocator, "a", 2, &loader);
    try testing.expectEqual(@as(usize, 4), loader.loads);
    _ = try cache.get(testing.allocator, "bb", 1, &loader);
    try testing.expectEqual(@as(usize, 5), loader.loads);

    loader.fail = true;
    try testing.expectError(error.BadData, cache.get(testing.allocator, "dddd", 1, &loader));
    loader.fail = false;
    _ = try cache.get(testing.allocator, "bb", 1, &loader);
    try testing.expectEqual(@as(usize, 5), loader.loads);
}

test "loadFile reads through std.Io" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const text = try identityCube(testing.allocator, 5, "");
    defer testing.allocator.free(text);
    try dir.dir.writeFile(testing.io, .{ .sub_path = "id.cube", .data = text });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/id.cube", .{&dir.sub_path});
    defer testing.allocator.free(path);
    var lut = try lut_math.loadFile(testing.io, testing.allocator, path);
    defer lut.deinit(testing.allocator);
    try expectIdentity(&lut);
}
