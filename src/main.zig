const std = @import("std");
const debug = std.debug;
const mem = std.mem;

const sqlite = @import("sqlite");
const curl = @import("curl");

const apida = @import("vtab_apida.zig");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) {
        std.debug.panic("leaks detected", .{});
    };
    const allocator = gpa.allocator();

    // Initiailze curl
    try curl.globalInit();
    defer curl.globalCleanup();

    //

    var departement_code: ?[]const u8 = null;

    var raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    var i: usize = 0;
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];

        if (mem.startsWith(u8, arg, "--departement-code=")) {
            const pos = mem.indexOfScalar(u8, arg, '=').?;
            departement_code = arg[pos + 1 ..];
        } else if (mem.eql(u8, arg, "--departement-code")) {
            i += 1;
            departement_code = raw_args[i];
        }
    }

    //

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

    var row_arena = std.heap.ArenaAllocator.init(allocator);
    defer row_arena.deinit();

    const Row = struct {
        town: []const u8,
        population: usize,
    };

    if (departement_code) |dc| {
        debug.print("getting all towns for departement code {s}\n", .{dc});

        var stmt = try db.prepareWithDiags("SELECT town, population FROM mytable WHERE departement_code = ?{[]const u8}", .{ .diags = &diags });
        defer stmt.deinit();

        var iter = try stmt.iterator(Row, .{dc});

        var count: usize = 0;
        while (try iter.nextAlloc(row_arena.allocator(), .{ .diags = &diags })) |row| {
            debug.print("town: {s}, population: {d}\n", .{ row.town, row.population });
            count += 1;
        }

        debug.print("count: {d}\n", .{count});
    } else {
        debug.print("getting all towns for all departements\n", .{});

        var stmt = try db.prepareWithDiags("SELECT town, population FROM mytable", .{ .diags = &diags });
        defer stmt.deinit();

        var iter = try stmt.iterator(Row, .{});

        var count: usize = 0;
        while (try iter.nextAlloc(row_arena.allocator(), .{ .diags = &diags })) |row| {
            debug.print("town: {s}, population: {d}\n", .{ row.town, row.population });
            count += 1;
        }

        debug.print("count: {d}\n", .{count});
    }
}
