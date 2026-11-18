const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addLittlefs(b, mod, target, optimize);
    const exe = b.addExecutable(.{
        .name = "wk",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the wk command line tool");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/aic.zig"),
        .target = target,
        .optimize = optimize,
    });
    addLittlefs(b, test_mod, target, optimize);
    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run.step);
}

/// 主机侧 littlefs：复用上游 BSD-1-Clause 实现（third_party/littlefs）。
fn addLittlefs(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) void {
    const tc = b.addTranslateC(.{
        .root_source_file = b.path("third_party/littlefs/lfs.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tc.addIncludePath(b.path("third_party/littlefs"));
    tc.defineCMacro("LFS_NO_ASSERT", null);
    const lfs_mod = tc.createModule();
    mod.addImport("lfs", lfs_mod);

    mod.addIncludePath(b.path("third_party/littlefs"));
    mod.addCSourceFiles(.{
        .files = &.{
            "third_party/littlefs/lfs.c",
            "third_party/littlefs/lfs_util.c",
        },
        .flags = &.{ "-std=c99", "-DLFS_NO_ASSERT" },
    });
    mod.link_libc = true;
}
