const std = @import("std");
const debug = std.debug;
const mem = std.mem;

const sqlite = @import("sqlite");
const curl = @import("curl.zig");

const vtab_apida = @import("vtab_apida.zig");
const vtab_user = @import("vtab_user.zig");

const logger = std.log.scoped(.main);

pub const Position = struct {
    longitude: f64,
    latitude: f64,
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) {
        std.debug.panic("leaks detected", .{});
    };
    const allocator = gpa.allocator();

    // Initiailze curl
    curl.globalInit();
    defer curl.globalCleanup();

    //

    var fetch_all_towns: bool = false;

    var raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    var i: usize = 0;
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];

        if (mem.eql(u8, arg, "--fetch-all-towns")) fetch_all_towns = true;
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

    try db.createVirtualTable("apida", &module_context, vtab_apida.Table);
    try db.createVirtualTable("user", &module_context, vtab_user.Table);

    var diags = sqlite.Diagnostics{};
    errdefer {
        logger.err("diags: {s}", .{diags});
    }

    try db.exec("CREATE VIRTUAL TABLE decoupage_administratif USING apida", .{ .diags = &diags }, .{});
    try db.exec("CREATE VIRTUAL TABLE user USING user(host=localhost, port=6379)", .{ .diags = &diags }, .{});

    var row_arena = std.heap.ArenaAllocator.init(allocator);
    defer row_arena.deinit();

    const start = std.time.milliTimestamp();

    if (fetch_all_towns) {
        defer {
            const now = std.time.milliTimestamp();
            logger.debug("fetched all towns in {d}ms", .{now - start});
        }

        var stmt = try db.prepareWithDiags(
            \\SELECT da.town, da.population, da.postal_code
            \\FROM decoupage_administratif da
        ,
            .{ .diags = &diags },
        );
        defer stmt.deinit();

        var iter = try stmt.iterator(
            struct {
                town: []const u8,
                population: i64,
                postal_code: i64,
            },
            .{},
        );

        var count: usize = 0;
        while (try iter.nextAlloc(row_arena.allocator(), .{ .diags = &diags })) |row| {
            logger.info("town=\"{s}\" population={d} postal code={d}", .{
                row.town,
                row.population,
                row.postal_code,
            });
            count += 1;
        }

        logger.info("count: {d}", .{count});
    } else {
        defer {
            const now = std.time.milliTimestamp();
            logger.debug("joined tables in {d}ms", .{now - start});
        }

        var n: usize = 0;
        while (n < 2) : (n += 1) {
            var stmt = try db.prepareWithDiags(
                \\SELECT u.rowid, u.id, u.name, u.postal_code, (
                \\  SELECT group_concat(da.town) FROM decoupage_administratif da WHERE da.postal_code = u.postal_code
                \\) AS town
                \\FROM user u
            ,
                .{ .diags = &diags },
            );
            defer stmt.deinit();

            var iter = try stmt.iterator(
                struct {
                    rowid: i64,
                    id: []const u8,
                    name: []const u8,
                    postal_code: i64,
                    town: []const u8,
                },
                .{},
            );

            var count: usize = 0;
            while (try iter.nextAlloc(row_arena.allocator(), .{ .diags = &diags })) |row| {
                logger.info("n#{d} row rowid={d} id=\"{s}\" name=\"{s}\": postal code: {d} town: \"{s}\"", .{
                    n,
                    row.rowid,
                    std.fmt.fmtSliceEscapeLower(row.id),
                    row.name,
                    row.postal_code,
                    row.town,
                });
                count += 1;
            }

            logger.info("n#{d} count: {d}", .{ n, count });
        }
    }
}
