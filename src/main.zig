const std = @import("std");

const sqlite = @import("sqlite");

const apida = @import("vtab_apida.zig");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) {
        std.debug.panic("leaks detected", .{});
    };

    var allocator = gpa.allocator();

    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .Memory = {} },
        .open_flags = .{ .write = true },
    });
    defer db.deinit();

    var module_context = sqlite.vtab.ModuleContext{
        .allocator = allocator,
    };

    try db.createVirtualTable("apida", &module_context, apida.Table);
}
