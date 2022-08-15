const std = @import("std");
const debug = std.debug;

const sqlite = @import("sqlite");
const curl = @import("curl");

const apida = @import("vtab_apida.zig");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) {
        std.debug.panic("leaks detected", .{});
    };

    // Initiailze curl
    try curl.globalInit();
    defer curl.globalCleanup();

    //

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

    var diags = sqlite.Diagnostics{};
    errdefer {
        debug.print("diags: {s}\n", .{diags});
    }

    try db.exec("CREATE VIRTUAL TABLE mytable USING apida", .{ .diags = &diags }, .{});

    //

    var stmt = try db.prepareWithDiags("SELECT town FROM mytable WHERE departement_code = ?{usize}", .{ .diags = &diags });
    defer stmt.deinit();

    var iter = try stmt.iterator([]const u8, .{@as(usize, 67)});

    var row_arena = std.heap.ArenaAllocator.init(allocator);
    defer row_arena.deinit();

    var count: usize = 0;
    while (try iter.nextAlloc(row_arena.allocator(), .{ .diags = &diags })) |row| {
        debug.print("row: {s}\n", .{row});
        count += 1;
    }
}
