const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite_dep = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });
    const sqlite_mod = sqlite_dep.module("sqlite");

    //

    const vtab_apida_ext_options = b.addOptions();

    const vtab_apida_ext_mod = b.createModule(.{
        .root_source_file = b.path("src/vtab_apida_ext.zig"),
        .target = target,
        .optimize = optimize,
    });
    vtab_apida_ext_mod.addImport("sqlite", sqlite_mod);
    vtab_apida_ext_mod.linkSystemLibrary("curl", .{ .use_pkg_config = .yes });
    vtab_apida_ext_mod.addOptions("build_options", vtab_apida_ext_options);

    const vtab_apida_ext = b.addSharedLibrary(.{
        .name = "apida",
        .root_module = vtab_apida_ext_mod,
    });

    b.installArtifact(vtab_apida_ext);

    //

    const vtab_user_ext_options = b.addOptions();

    const vtab_user_ext_mod = b.createModule(.{
        .root_source_file = b.path("src/vtab_user_ext.zig"),
        .target = target,
        .optimize = optimize,
    });
    vtab_user_ext_mod.addImport("sqlite", sqlite_mod);
    vtab_user_ext_mod.linkSystemLibrary("hiredis", .{ .use_pkg_config = .yes });
    vtab_user_ext_mod.addOptions("build_options", vtab_user_ext_options);

    const vtab_user_ext = b.addSharedLibrary(.{
        .name = "user",
        .root_module = vtab_user_ext_mod,
    });

    b.installArtifact(vtab_user_ext);

    //

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("sqlite", sqlite_mod);

    const exe = b.addExecutable(.{
        .name = "zig-sqlite-demo",
        .root_module = exe_mod,
    });
    exe.linkSystemLibrary("curl");
    exe.linkSystemLibrary("hiredis");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
