const std = @import("std");
const debug = std.debug;
const mem = std.mem;

const sqlite = @import("sqlite");
const curl = @import("curl");

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

    try db.createVirtualTable("apida", &module_context, vtab_apida.Table);
    try db.createVirtualTable("user", &module_context, vtab_user.Table);

    var diags = sqlite.Diagnostics{};
    errdefer {
        logger.err("diags: {s}", .{diags});
    }

    try db.exec("CREATE VIRTUAL TABLE decoupage_administratif USING apida", .{ .diags = &diags }, .{});
    try db.exec("CREATE VIRTUAL TABLE user USING user(host=localhost, port=6379)", .{ .diags = &diags }, .{});

    //

    var n: usize = 0;
    while (n < 2) : (n += 1) {
        var row_arena = std.heap.ArenaAllocator.init(allocator);
        defer row_arena.deinit();

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
                postal_code: f64,
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
