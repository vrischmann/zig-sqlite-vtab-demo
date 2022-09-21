const std = @import("std");
const build_options = @import("build_options");
const debug = std.debug;
const fmt = std.fmt;
const json = std.json;
const mem = std.mem;

const sqlite = @import("sqlite");
const curl = @import("curl.zig");

const Position = @import("main.zig").Position;

const logger = std.log.scoped(.vtab_apida);

/// Internal type
const GeoDataEntry = struct {
    town: []const u8,
    postal_code: isize,
    departement_code: []const u8,
    region_code: []const u8,
    population: isize,
    position: Position,
};

const towns_endpoint = "https://geo.api.gouv.fr/communes?fields=nom,code,codeDepartement,codeRegion,codesPostaux,population,centre";
const towns_for_departement_endpoint = "https://geo.api.gouv.fr/departements/{s}/communes?fields=nom,code,codeDepartement,codeRegion,codesPostaux,population,centre";

/// Direct mapping to the JSON returned by the API
const GeoDataJSONEntry = struct {
    nom: []const u8,
    code: []const u8,
    codeDepartement: []const u8,
    codeRegion: []const u8,
    codesPostaux: []const []const u8,
    population: ?isize = null,
    centre: struct {
        coordinates: [2]f64,
    },
};

const FetchAllGeoDataError = error{
    InvalidStatusCode,
} || mem.Allocator.Error || fmt.ParseIntError || json.ParseError([]GeoDataJSONEntry) || curl.Error;

/// Fetch the Geo data. The endpoint must be either:
/// * the general `towns_endpoint` which will return _all_ towns in France
/// * a endpoint built using `towns_for_departement_endpoint` which will return all towns for a specific departement.
fn fetchAllGeoData(allocator: mem.Allocator, endpoint: [:0]const u8) FetchAllGeoDataError![]GeoDataEntry {
    const start = std.time.milliTimestamp();
    defer {
        const now = std.time.milliTimestamp();
        logger.debug("fetched data for endpoint \"{s}\" in {d}ms", .{ endpoint, now - start });
    }

    // NOTE(vincent): don't release Zig-allocated resources here, we always pass an arena as allocator and handle errors in the calling function

    // Perform the HTTP request using curl
    var client = try curl.Client.init();
    defer client.deinit();

    const response = try client.get(allocator, endpoint);

    if (response.status != 200) {
        logger.warn("fetchAllGeoData: got status code {d}", .{response.status});
        logger.warn("fetchAllGeoData: response body is {s}", .{response.body});
        return error.InvalidStatusCode;
    }

    //

    var token_stream = json.TokenStream.init(response.body);
    const data = try json.parse([]GeoDataJSONEntry, &token_stream, .{
        .allocator = allocator,
        .ignore_unknown_fields = true,
    });

    var result = try allocator.alloc(GeoDataEntry, data.len);
    for (result) |*entry, i| {
        const raw_data = data[i];

        entry.* = .{
            .town = raw_data.nom,
            .postal_code = if (raw_data.codesPostaux.len > 0)
                try fmt.parseInt(isize, raw_data.codesPostaux[0], 10)
            else
                0,
            .departement_code = raw_data.codeDepartement,
            .region_code = raw_data.codeRegion,
            .population = raw_data.population orelse 0,
            .position = .{
                .longitude = raw_data.centre.coordinates[0],
                .latitude = raw_data.centre.coordinates[1],
            },
        };
    }

    return result;
}

pub const Table = struct {
    pub const Cursor = TableCursor;

    arena_state: std.heap.ArenaAllocator.State,
    schema: [:0]const u8,

    pub const InitError = error{} || mem.Allocator.Error || fmt.ParseIntError;

    pub fn init(gpa: mem.Allocator, diags: *sqlite.vtab.VTabDiagnostics, args: []const sqlite.vtab.ModuleArgument) InitError!*Table {
        _ = diags;
        _ = args;

        var arena = std.heap.ArenaAllocator.init(gpa);
        const allocator = arena.allocator();

        var res = try allocator.create(Table);
        errdefer res.deinit(gpa);

        // Build the schema
        res.schema = try allocator.dupeZ(u8,
            \\CREATE TABLE x(
            \\  town TEXT,
            \\  postal_code INTEGER,
            \\  departement_code INTEGER,
            \\  region_code INTEGER,
            \\  population INTEGER,
            \\  longitude REAL,
            \\  latitude REAL
            \\)
        );

        res.arena_state = arena.state;

        return res;
    }

    pub fn deinit(table: *Table, gpa: mem.Allocator) void {
        table.arena_state.promote(gpa).deinit();
    }

    pub const BuildBestIndexError = error{} || mem.Allocator.Error;

    pub fn buildBestIndex(table: *Table, diags: *sqlite.vtab.VTabDiagnostics, builder: *sqlite.vtab.BestIndexBuilder) BuildBestIndexError!void {
        _ = table;
        _ = diags;

        var id_str_writer = builder.id_str_buffer.writer();

        // We can only use the departement code for filtering.
        var argv_index: i32 = 0;
        for (builder.constraints) |*constraint| {
            if (constraint.usable and constraint.op == .eq) {
                argv_index += 1;
                constraint.usage.argv_index = argv_index;

                if (argv_index > 0) try id_str_writer.writeByte('|');
                try id_str_writer.print("{d}", .{constraint.column});
            }
        }

        builder.id.str = builder.id_str_buffer.toOwnedSlice();
        builder.build();
    }
};

pub const TableCursor = struct {
    allocator: mem.Allocator,
    parent: *Table,

    data_arena: std.heap.ArenaAllocator,
    data: []GeoDataEntry,
    pos: usize,

    pub const InitError = error{} || mem.Allocator.Error;

    pub fn init(gpa: mem.Allocator, parent: *Table) InitError!*TableCursor {
        var res = try gpa.create(TableCursor);
        res.* = .{
            .allocator = gpa,
            .parent = parent,
            .data_arena = std.heap.ArenaAllocator.init(gpa),
            .data = &[_]GeoDataEntry{},
            .pos = 0,
        };
        return res;
    }

    pub fn deinit(cursor: *TableCursor) void {
        cursor.data_arena.deinit();
        cursor.allocator.destroy(cursor);
    }

    pub const FilterError = error{InvalidColumn} || FetchAllGeoDataError;

    pub fn filter(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics, index: sqlite.vtab.IndexIdentifier, args: []sqlite.vtab.FilterArg) FilterError!void {
        cursor.data_arena.deinit();
        cursor.data_arena = std.heap.ArenaAllocator.init(cursor.allocator);

        const allocator = cursor.data_arena.allocator();

        // Parse the index identifier

        var town: ?[]const u8 = null;
        var postal_code: ?[]const u8 = null;
        var departement_code: ?[]const u8 = null;

        var id = index.str;

        var token_iterator = mem.tokenize(u8, id, "|");
        var i: usize = 0;
        while (token_iterator.next()) |token| {
            const arg = args[i];

            const col = try fmt.parseInt(i32, mem.trimRight(u8, token, " "), 10);
            if (col == 0) {
                town = arg.as([]const u8);
            } else if (col == 1) {
                postal_code = arg.as([]const u8);
            } else if (col == 2) {
                departement_code = arg.as([]const u8);
            }

            i += 1;
        }

        //

        const endpoint = if (town) |s|
            try mem.concatWithSentinel(allocator, u8, &[_][]const u8{
                towns_endpoint,
                "&nom=",
                s,
            }, 0)
        else if (postal_code) |s|
            try mem.concatWithSentinel(allocator, u8, &[_][]const u8{
                towns_endpoint,
                "&codePostal=",
                s,
            }, 0)
        else if (departement_code) |s|
            try fmt.allocPrintZ(allocator, towns_for_departement_endpoint, .{s})
        else
            towns_endpoint;

        //

        cursor.data = fetchAllGeoData(allocator, endpoint) catch |err| {
            diags.setErrorMessage("unable to fetch the Geo Data using the endpoint {s} error is {}", .{ towns_endpoint, err });
            return err;
        };
    }

    pub const NextError = error{};

    pub fn next(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics) NextError!void {
        _ = diags;

        cursor.pos += 1;
    }

    pub const HasNextError = error{};

    pub fn hasNext(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics) HasNextError!bool {
        _ = diags;

        return cursor.pos < cursor.data.len;
    }

    pub const ColumnError = error{InvalidColumn};

    pub const Column = union(enum) {
        town: []const u8,
        postal_code: isize,
        departement_code: []const u8,
        region_code: []const u8,
        population: isize,
        longitude: f64,
        latitude: f64,
    };

    pub fn column(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics, column_number: i32) ColumnError!Column {
        const entry = cursor.data[cursor.pos];

        switch (column_number) {
            0 => return Column{ .town = entry.town },
            1 => return Column{ .postal_code = entry.postal_code },
            2 => return Column{ .departement_code = entry.departement_code },
            3 => return Column{ .region_code = entry.region_code },
            4 => return Column{ .population = entry.population },
            5 => return Column{ .longitude = entry.position.longitude },
            6 => return Column{ .latitude = entry.position.latitude },
            else => {
                diags.setErrorMessage("column number {d} is invalid", .{column_number});
                return error.InvalidColumn;
            },
        }
    }

    pub const RowIDError = error{};

    pub fn rowId(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics) RowIDError!i64 {
        _ = diags;

        return @intCast(i64, cursor.pos);
    }
};
