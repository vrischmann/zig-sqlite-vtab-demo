const std = @import("std");
const build_options = @import("build_options");
const debug = std.debug;
const fmt = std.fmt;
const json = std.json;
const mem = std.mem;

const sqlite = @import("sqlite");
const curl = @import("curl");
const c = sqlite.c;

const Position = struct {
    longitude: f64,
    latitude: f64,
};

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
    // NOTE(vincent): don't release Zig-allocated resources here, we always pass an arena as allocator and handle errors in the calling function

    // Perform the HTTP request using curl

    const Fifo = std.fifo.LinearFifo(u8, .{ .Dynamic = {} });

    var fifo = Fifo.init(allocator);
    try fifo.ensureTotalCapacity(40000);

    var easy = try curl.Easy.init();
    defer easy.cleanup();

    try easy.setUrl(endpoint);
    try easy.setSslVerifyPeer(false);
    try easy.setAcceptEncodingGzip();
    try easy.setWriteFn(curl.writeToFifo(Fifo));
    try easy.setWriteData(&fifo);
    try easy.perform();
    const code = try easy.getResponseCode();
    if (code != 200) {
        debug.print("fetchAllGeoData: got status code {d}\n", .{code});
        debug.print("fetchAllGeoData: response body is {s}\n", .{fifo.readableSlice(0)});
        return error.InvalidStatusCode;
    }

    //

    var token_stream = json.TokenStream.init(fifo.readableSlice(0));
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
    curl: *curl.Easy,
    schema: [:0]const u8,

    pub const InitError = error{} || mem.Allocator.Error || fmt.ParseIntError || curl.Error;

    pub fn init(gpa: mem.Allocator, diags: *sqlite.vtab.VTabDiagnostics, args: []const []const u8) InitError!*Table {
        _ = diags;
        _ = args;

        var arena = std.heap.ArenaAllocator.init(gpa);
        const allocator = arena.allocator();

        var res = try allocator.create(Table);
        errdefer res.deinit(gpa);

        res.curl = try curl.Easy.init();

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
        table.curl.cleanup();
        table.arena_state.promote(gpa).deinit();
    }

    pub const BuildBestIndexError = error{} || mem.Allocator.Error;

    pub fn buildBestIndex(table: *Table, diags: *sqlite.vtab.VTabDiagnostics, builder: *sqlite.vtab.BestIndexBuilder) BuildBestIndexError!void {
        _ = table;
        _ = diags;

        // We can only use the departement code for filtering.
        for (builder.constraints) |*constraint| {
            if (constraint.op == .eq and constraint.column == 2) {
                constraint.usage.argv_index = 1;
                builder.id.num = 100;
                break;
            }
        }

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

    pub const FilterError = error{} || FetchAllGeoDataError;

    pub fn filter(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics, index: sqlite.vtab.IndexIdentifier, args: []sqlite.vtab.FilterArg) FilterError!void {
        cursor.data_arena.deinit();
        cursor.data_arena = std.heap.ArenaAllocator.init(cursor.allocator);

        const allocator = cursor.data_arena.allocator();

        // If an index is used try to filter by calling the appropriate API endpoint
        if (index.num == 100) {
            const endpoint = try fmt.allocPrintZ(allocator, towns_for_departement_endpoint, .{
                args[0].as([]const u8),
            });
            defer allocator.free(endpoint);

            if (fetchAllGeoData(allocator, endpoint)) |data| {
                cursor.data = data;
                debug.print("fetched data for endpoint {s}\n", .{endpoint});
                return;
            } else |err| {
                debug.print("fetchAllGeoData for {s} failed, err: {}, falling back to generic endpoint\n", .{ endpoint, err });
            }
        }

        cursor.data = fetchAllGeoData(allocator, towns_endpoint) catch |err| {
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
