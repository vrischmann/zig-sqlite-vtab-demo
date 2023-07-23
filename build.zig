const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    var target = b.standardTargetOptions(.{});
    const target_info = try std.zig.system.NativeTargetInfo.detect(target);
    if (target_info.target.os.tag == .linux and target_info.target.abi == .gnu) {
        target.setGnuLibCVersion(2, 28, 0);
    }
    const optimize = b.standardOptimizeOption(.{});

    const sqlite = b.addStaticLibrary(.{
        .name = "sqlite",
        .target = target,
        .optimize = optimize,
    });
    sqlite.addCSourceFile("third_party/zig-sqlite/c/sqlite3.c", &[_][]const u8{
        "-std=c99",
        "-DSQLITE_ENABLE_JSON1",
    });
    sqlite.addIncludePath("third_party/zig-sqlite/c");
    sqlite.linkLibC();

    //

    const vtab_apida_ext = b.addSharedLibrary(.{
        .name = "apida",
        .root_source_file = .{ .path = "src/vtab_apida_ext.zig" },
        .target = target,
        .optimize = optimize,
    });

    vtab_apida_ext.addIncludePath("third_party/zig-sqlite/c");
    vtab_apida_ext.addAnonymousModule("sqlite", .{
        .source_file = .{ .path = "third_party/zig-sqlite/sqlite.zig" },
    });

    vtab_apida_ext.addIncludePath("/usr/include");
    vtab_apida_ext.addLibraryPath("/usr/lib64");

    vtab_apida_ext.linkLibrary(sqlite);
    vtab_apida_ext.linkSystemLibrary("curl");

    const vtab_apida_ext_options = b.addOptions();
    vtab_apida_ext.addOptions("build_options", vtab_apida_ext_options);

    b.installArtifact(vtab_apida_ext);

    //

    const vtab_user_ext = b.addSharedLibrary(.{
        .name = "user",
        .root_source_file = .{ .path = "src/vtab_user_ext.zig" },
        .target = target,
        .optimize = optimize,
    });

    vtab_user_ext.addIncludePath("third_party/zig-sqlite/c");
    vtab_user_ext.addAnonymousModule("sqlite", .{
        .source_file = .{ .path = "third_party/zig-sqlite/sqlite.zig" },
    });

    vtab_user_ext.addIncludePath("/usr/include");
    vtab_user_ext.addLibraryPath("/usr/lib64");

    vtab_user_ext.linkLibrary(sqlite);
    vtab_user_ext.linkSystemLibrary("hiredis");

    const vtab_user_ext_options = b.addOptions();
    vtab_user_ext.addOptions("build_options", vtab_user_ext_options);

    b.installArtifact(vtab_user_ext);

    //

    const exe = b.addExecutable(.{
        .name = "zig-sqlite-demo",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.addIncludePath("third_party/zig-sqlite/c");
    exe.addAnonymousModule("sqlite", .{
        .source_file = .{ .path = "third_party/zig-sqlite/sqlite.zig" },
    });

    exe.addIncludePath("/usr/include");
    exe.addLibraryPath("/usr/lib64");

    exe.linkLibrary(sqlite);
    exe.linkSystemLibrary("hiredis");
    exe.linkSystemLibrary("curl");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
