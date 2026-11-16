const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug information from release artifacts") orelse false;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    // Kernel ABI CPU references (Unit 4): gpu/equihash_cpu_ref.c plus the
    // included public-domain BLAKE2 reference. Device kernels (Unit 5)
    // implement the same gpu/equihash_gpu.h header.
    exe_mod.addIncludePath(b.path("gpu"));
    exe_mod.addIncludePath(b.path("gpu/thirdparty"));
    exe_mod.addCSourceFile(.{
        .file = b.path("gpu/equihash_cpu_ref.c"),
        .flags = &.{ "-std=c99", "-O2", b.fmt("-ffile-prefix-map={s}=.", .{b.build_root.path orelse "."}) },
    });
    exe_mod.addCSourceFile(.{
        .file = b.path("gpu/thirdparty/blake2b-ref.c"),
        .flags = &.{ "-std=c99", "-O2" },
    });
    const exe = b.addExecutable(.{
        .name = "zcash-miner",
        .root_module = exe_mod,
    });
    exe.linkLibC();
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the miner");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
