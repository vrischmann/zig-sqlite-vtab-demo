const std = @import("std");

const libcurl = @import("third_party/zig-libcurl/libcurl.zig");
const libzlib = @import("third_party/zig-zlib/zlib.zig");
const libmbedtls = @import("third_party/zig-mbedtls/mbedtls.zig");
const libssh2 = @import("third_party/zig-libssh2/libssh2.zig");

pub fn build(b: *std.build.Builder) !void {
    var target = b.standardTargetOptions(.{});
    const target_info = try std.zig.system.NativeTargetInfo.detect(b.allocator, target);
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
    sqlite.addIncludeDir("third_party/zig-sqlite/c");
    sqlite.linkLibC();

    const zlib = libzlib.create(b, target, mode);
    const mbedtls = libmbedtls.create(b, target, mode);
    const ssh2 = libssh2.create(b, target, mode);
    const curl = try libcurl.create(b, target, mode);

    mbedtls.link(ssh2.step);
    ssh2.link(curl.step);
    zlib.link(curl.step, .{});
    mbedtls.link(curl.step);

    //

    if (false) {
        const vtab_apida_ext = b.addSharedLibrary("apida", "src/vtab_apida_ext.zig", .unversioned);
        vtab_apida_ext.force_pic = true;
        vtab_apida_ext.setTarget(target);
        vtab_apida_ext.setBuildMode(mode);
        vtab_apida_ext.addIncludeDir("/usr/include");
        vtab_apida_ext.addLibraryPath("/usr/lib64");
        vtab_apida_ext.addPackagePath("sqlite", "third_party/zig-sqlite/sqlite.zig");
        vtab_apida_ext.linkSystemLibrary("sqlite3");
        vtab_apida_ext.linkLibC();
        vtab_apida_ext.install();

        const vtab_apida_ext_options = b.addOptions();
        vtab_apida_ext.addOptions("build_options", vtab_apida_ext_options);
    }

    //

    const exe = b.addExecutable("zig-sqlite-demo", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.linkLibrary(sqlite);
    exe.addIncludeDir("third_party/zig-sqlite/c");
    exe.addPackagePath("sqlite", "third_party/zig-sqlite/sqlite.zig");
    mbedtls.link(exe);
    ssh2.link(exe);
    zlib.link(exe, .{});
    curl.link(exe, .{ .import_name = "curl" });
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
