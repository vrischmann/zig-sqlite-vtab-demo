const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    var target = b.standardTargetOptions(.{});
    const target_info = try std.zig.system.NativeTargetInfo.detect(target);
    if (target_info.target.os.tag == .linux and target_info.target.abi == .gnu) {
        target.setGnuLibCVersion(2, 28, 0);
    }
    const mode = b.standardReleaseOptions();

    const sqlite = b.addStaticLibrary("sqlite", null);
    sqlite.addCSourceFile("third_party/zig-sqlite/c/sqlite3.c", &[_][]const u8{
        "-std=c99",
        "-DSQLITE_ENABLE_JSON1",
    });
    sqlite.setTarget(target);
    sqlite.setBuildMode(mode);
    sqlite.addIncludePath("third_party/zig-sqlite/c");
    sqlite.linkLibC();

    //

    if (true) {
        const vtab_apida_ext = b.addSharedLibrary("apida", "src/vtab_apida_ext.zig", .unversioned);
        vtab_apida_ext.force_pic = true;
        vtab_apida_ext.setTarget(target);
        vtab_apida_ext.setBuildMode(mode);
        vtab_apida_ext.use_stage1 = true;

        vtab_apida_ext.addIncludePath("third_party/zig-sqlite/c");
        vtab_apida_ext.addPackagePath("sqlite", "third_party/zig-sqlite/sqlite.zig");

        vtab_apida_ext.install();

        vtab_apida_ext.addIncludePath("/usr/include");
        vtab_apida_ext.addLibraryPath("/usr/lib64");

        vtab_apida_ext.linkLibrary(sqlite);
        vtab_apida_ext.linkSystemLibrary("hiredis");
        vtab_apida_ext.linkSystemLibrary("curl");

        const vtab_apida_ext_options = b.addOptions();
        vtab_apida_ext.addOptions("build_options", vtab_apida_ext_options);
    }

    //

    const exe = b.addExecutable("zig-sqlite-demo", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.use_stage1 = true;

    exe.addIncludePath("third_party/zig-sqlite/c");
    exe.addPackagePath("sqlite", "third_party/zig-sqlite/sqlite.zig");

    exe.addIncludePath("/usr/include");
    exe.addLibraryPath("/usr/lib64");

    exe.linkLibrary(sqlite);
    exe.linkSystemLibrary("hiredis");
    exe.linkSystemLibrary("curl");

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
