const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // libunicorn 的目录(含 libunicorn.so.2);默认用 venv 里 pip 装的,可用 -Dunicorn-lib= 覆盖
    const unicorn_dir = b.option([]const u8, "unicorn-lib", "directory containing libunicorn.so.2") orelse "../venv/lib/python3.14/site-packages/unicorn/lib";
    const so_path = b.fmt("{s}/libunicorn.so.2", .{unicorn_dir});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.link_libc = true;
    mod.addLibraryPath(.{ .cwd_relative = unicorn_dir });
    mod.addObjectFile(.{ .cwd_relative = so_path });
    mod.addRPath(.{ .cwd_relative = unicorn_dir });

    const exe = b.addExecutable(.{ .name = "lumin-dumper", .root_module = mod });
    b.installArtifact(exe);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "run self-tests");
    test_step.dependOn(&run_tests.step);
}
