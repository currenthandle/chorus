const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addIncludePath(b.path("vendor/miniaudio"));
    exe_mod.addCSourceFile(.{
        .file = b.path("vendor/miniaudio/miniaudio.c"),
        .flags = &.{
            "-std=c11",
            "-fno-sanitize=undefined",
            "-DMA_NO_RUNTIME_LINKING",
        },
    });
    exe_mod.link_libc = true;

    switch (target.result.os.tag) {
        .macos => {
            exe_mod.linkFramework("CoreFoundation", .{});
            exe_mod.linkFramework("CoreAudio", .{});
            exe_mod.linkFramework("AudioToolbox", .{});
            exe_mod.linkFramework("AudioUnit", .{});
        },
        .linux => {
            exe_mod.linkSystemLibrary("pthread", .{});
            exe_mod.linkSystemLibrary("m", .{});
            exe_mod.linkSystemLibrary("dl", .{});
        },
        .windows => {},
        else => {},
    }

    const exe = b.addExecutable(.{
        .name = "chorus",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run chorus");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
