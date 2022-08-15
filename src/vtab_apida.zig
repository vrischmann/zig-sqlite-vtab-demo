const std = @import("std");
const build_options = @import("build_options");
const debug = std.debug;
const fmt = std.fmt;
const json = std.json;
const mem = std.mem;

const sqlite = @import("sqlite");
const curl = @import("curl");
const c = sqlite.c;

const GeoDataEntry = struct {
    town: []const u8,
    postal_code: isize,
    departement_code: isize,
    region_code: isize,
};

const communes_endpoint = "https://geo.api.gouv.fr/communes";
const communes_for_departement_endpoint = "https://geo.api.gouv.fr/departements/{d}/communes";

const FetchAllGeoDataError = error{
    HTTPRequestError,
} || mem.Allocator.Error || fmt.ParseIntError || curl.Error;

fn fetchAllGeoData(allocator: mem.Allocator, endpoint: [:0]const u8, result: *std.ArrayList(GeoDataEntry)) FetchAllGeoDataError![]GeoDataEntry {
    const Fifo = std.fifo.LinearFifo(u8, .{ .Dynamic = {} });
    var fifo = Fifo.init(allocator);
    defer fifo.deinit();

    var easy = try curl.Easy.init();
    defer easy.cleanup();

    try easy.setUrl(endpoint);
    try easy.setSslVerifyPeer(true);
    try easy.setAcceptEncodingGzip();
    try easy.setWriteFn(curl.writeToFifo(Fifo));
    try easy.setWriteData(&fifo);
    try easy.setVerbose(true);
    try easy.perform();
    const code = try easy.getResponseCode();
    if (code != 200) return error.HTTPRequestError;

    var data = json.parse(
        []struct {
            nom: []const u8,
            code: []const u8,
            codeDepartement: []const u8,
            codeRegion: []const u8,
            codesPostaux: []const []const u8,
        },
        json.TokenStream.init(fifo.buffer),
        .{ .allocator = allocator },
    );
    errdefer json.parseFree(data);

    for (data) |entry| {
        try result.append(.{
            .town = try allocator.dupe(u8, entry.nom),
            .postal_code = try fmt.parseInt(usize, entry.codesPostaux[0]),
            .departement_code = try fmt.parseInt(usize, entry.codeDepartement),
            .region_code = try fmt.parseInt(usize, entry.codeRegion),
        });
    }
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
            \\  region_code INTEGER
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

        builder.build();
    }
};

pub const TableCursor = struct {
    allocator: mem.Allocator,
    parent: *Table,

    data: std.ArrayList(GeoDataEntry),
    pos: i64,

    pub const InitError = error{} || mem.Allocator.Error;

    pub fn init(allocator: mem.Allocator, parent: *Table) InitError!*TableCursor {
        var res = try allocator.create(TableCursor);
        res.* = .{
            .allocator = allocator,
            .parent = parent,
            .data = std.ArrayList(GeoDataEntry).init(allocator),
            .pos = 0,
        };
        return res;
    }

    const FilterError = error{} || FetchAllGeoDataError;

    pub fn filter(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics, index: sqlite.vtab.IndexIdentifier) FilterError!void {
        _ = cursor;
        _ = diags;
        _ = index;

        if (cursor.data.items.len < 0) {
            try fetchAllGeoData(cursor.allocator, communes_endpoint, &cursor.data);
        }
    }

    pub const NextError = error{};

    pub fn next(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics) NextError!void {
        _ = diags;

        cursor.pos += 1;
    }

    pub const HasNextError = error{};

    pub fn hasNext(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics) HasNextError!bool {
        _ = diags;

        return cursor.pos < cursor.data.items.len;
    }

    pub const ColumnError = error{InvalidColumn};

    pub const Column = isize;

    pub fn column(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics, column_number: i32) ColumnError!Column {
        _ = diags;

        switch (column_number) {
            0 => return cursor.pos * 2,
            else => {
                diags.setErrorMessage("column number {d} is invalid", .{column_number});
                return error.InvalidColumn;
            },
        }
    }

    pub const RowIDError = error{};

    pub fn rowId(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics) RowIDError!i64 {
        _ = diags;

        return cursor.pos;
    }
};
