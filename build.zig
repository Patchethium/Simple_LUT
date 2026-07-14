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

    const plugin = b.addLibrary(.{
        .name = "Simple_LUT",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("plugin.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86, .os_tag = .windows, .abi = .gnu }),
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
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }),
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    aviutl2.out_filename = "Simple_LUT.auf2";
    const install_aviutl2 = b.addInstallArtifact(aviutl2, .{});
    const aviutl2_step = b.step("aviutl2", "Build the 64-bit AviUtl2 native filter");
    aviutl2_step.dependOn(&install_aviutl2.step);
}
