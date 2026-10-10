const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "simple-lut",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.linkSystemLibrary("png", .{});
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args|
        run_cmd.addArgs(args)
    else
        run_cmd.addArgs(&.{ "test/sample.png", "test/MagicHour.cube", "test/output.png", "tetrahedral" });
    const run_step = b.step("run", "Run the PNG LUT transformer");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("lut_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run the LUT parser, interpolation, and cache tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const benchmark = b.addExecutable(.{
        .name = "simple-lut-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    benchmark.root_module.linkSystemLibrary("png", .{});
    const benchmark_cmd = b.addRunArtifact(benchmark);
    if (b.args) |args| benchmark_cmd.addArgs(args);
    const benchmark_step = b.step("benchmark", "Benchmark interpolation without PNG or LUT loading");
    benchmark_step.dependOn(&benchmark_cmd.step);

    const golden = b.addSystemCommand(&.{ "sh", "tools/compare_ffmpeg.sh" });
    golden.addArtifactArg(exe);
    if (b.args) |args| golden.addArgs(args);
    golden.has_side_effects = true;
    const golden_step = b.step("golden", "Compare the PNG tool against ffmpeg's lut3d filter (needs ffmpeg)");
    golden_step.dependOn(&golden.step);

    const windows_x86 = b.resolveTargetQuery(.{ .cpu_arch = .x86, .os_tag = .windows, .abi = .gnu });
    const windows_x64 = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });

    const plugin = b.addLibrary(.{
        .name = "Simple_LUT",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("plugin.zig"),
            .target = windows_x86,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const install_plugin = b.addInstallArtifact(plugin, .{});
    const plugin_step = b.step("plugin", "Build the 32-bit Windows AviUtl plugin");
    plugin_step.dependOn(&install_plugin.step);

    const aviutl2 = b.addLibrary(.{
        .name = "Simple_LUT",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("aviutl2.zig"),
            .target = windows_x64,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    aviutl2.out_filename = "Simple_LUT.auf2";
    const install_aviutl2 = b.addInstallArtifact(aviutl2, .{});
    const aviutl2_step = b.step("aviutl2", "Build the 64-bit AviUtl2 native filter");
    aviutl2_step.dependOn(&install_aviutl2.step);

    // Windows test harnesses: run them with tools/run_harness.sh (wine) or natively on Windows.
    const harness_step = b.step("harness", "Build the Windows harnesses for the .dll and .auf2");
    const harnesses = [_]struct { name: []const u8, source: []const u8, import: []const u8, root: []const u8, target: std.Build.ResolvedTarget }{
        .{ .name = "aviutl2_harness", .source = "harness/aviutl2_harness.zig", .import = "aviutl2", .root = "aviutl2.zig", .target = windows_x64 },
        .{ .name = "legacy_harness", .source = "harness/legacy_harness.zig", .import = "legacy", .root = "plugin.zig", .target = windows_x86 },
    };
    for (harnesses) |harness| {
        const module = b.createModule(.{
            .root_source_file = b.path(harness.source),
            .target = harness.target,
            .optimize = optimize,
            .link_libc = true,
        });
        module.addImport(harness.import, b.createModule(.{
            .root_source_file = b.path(harness.root),
            .target = harness.target,
            .optimize = optimize,
            .link_libc = true,
        }));
        const executable = b.addExecutable(.{ .name = harness.name, .root_module = module });
        harness_step.dependOn(&b.addInstallArtifact(executable, .{ .dest_dir = .{ .override = .{ .custom = "harness" } } }).step);
    }
    harness_step.dependOn(&install_plugin.step);
    harness_step.dependOn(&install_aviutl2.step);

    // Regenerates the AviUtl2 struct layouts from a local SDK checkout and compares them with
    // aviutl2_layout.zig, which aviutl2.zig asserts against at compile time.
    const sdk_dir = b.option([]const u8, "aviutl2-sdk", "AviUtl2 SDK directory for sdk-check (default ../aviutl2_sdk)") orelse "../aviutl2_sdk";
    const probe_module = b.createModule(.{ .target = windows_x64, .optimize = .Debug, .link_libcpp = true });
    probe_module.addCSourceFile(.{ .file = b.path("tools/sdk_layout_probe.cpp"), .flags = &.{"-w"} });
    probe_module.addIncludePath(.{ .cwd_relative = sdk_dir });
    const probe = b.addExecutable(.{ .name = "sdk_layout_probe", .root_module = probe_module });
    const run_probe = if (b.graph.host.result.os.tag == .windows) b.addRunArtifact(probe) else b.addSystemCommand(&.{"wine"});
    if (b.graph.host.result.os.tag != .windows) run_probe.addArtifactArg(probe);
    run_probe.setEnvironmentVariable("WINEDEBUG", "-all");
    run_probe.has_side_effects = true;
    const probe_output = run_probe.captureStdOut(.{});
    const compare = b.addSystemCommand(&.{ "sh", "-c", "tr -d '\\r' < \"$1\" | diff -u aviutl2_layout.zig - && echo 'aviutl2_layout.zig matches the SDK'", "sdk-check" });
    compare.addFileArg(probe_output);
    compare.has_side_effects = true;
    const sdk_step = b.step("sdk-check", "Check aviutl2_layout.zig against the AviUtl2 SDK headers (needs wine off Windows)");
    sdk_step.dependOn(&compare.step);

    // Do-nothing AviUtl2 filters for checking plugin loading: one from the official SDK header
    // (C++, needs the SDK), one built like Simple_LUT.auf2. Both log to C:\Users\Public\aviutl2_noop.log.
    const debug_step = b.step("debug-plugins", "Build no-op AviUtl2 filters for plugin loading tests");
    const noop_zig_module = b.createModule(.{
        .root_source_file = b.path("debug/noop_filter.zig"),
        .target = windows_x64,
        .optimize = optimize,
        .link_libc = true,
    });
    noop_zig_module.addImport("aviutl2_sdk", b.createModule(.{ .root_source_file = b.path("aviutl2_sdk.zig"), .target = windows_x64, .optimize = optimize }));
    const noop_cpp_module = b.createModule(.{ .target = windows_x64, .optimize = optimize, .link_libc = true });
    noop_cpp_module.addCSourceFile(.{ .file = b.path("debug/noop_filter.cpp"), .flags = &.{"-w"} });
    noop_cpp_module.addIncludePath(.{ .cwd_relative = sdk_dir });
    for ([_]struct { name: []const u8, module: *std.Build.Module }{
        .{ .name = "NoopFilterZig", .module = noop_zig_module },
        .{ .name = "NoopFilterCpp", .module = noop_cpp_module },
    }) |noop| {
        const library = b.addLibrary(.{ .name = noop.name, .linkage = .dynamic, .root_module = noop.module });
        library.out_filename = b.fmt("{s}.auf2", .{noop.name});
        debug_step.dependOn(&b.addInstallArtifact(library, .{ .dest_dir = .{ .override = .{ .custom = "debug" } }, .pdb_dir = .disabled, .implib_dir = .disabled }).step);
    }
}
