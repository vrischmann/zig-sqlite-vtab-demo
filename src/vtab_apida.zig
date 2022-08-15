const std = @import("std");
const build_options = @import("build_options");
const debug = std.debug;
const fmt = std.fmt;
const mem = std.mem;

const sqlite = @import("sqlite");
const c = sqlite.c;

pub const Table = struct {
    pub const Cursor = TableCursor;

    arena_state: std.heap.ArenaAllocator.State,
    schema: [:0]const u8,

    pub const InitError = error{} || mem.Allocator.Error || fmt.ParseIntError;

    pub fn init(gpa: mem.Allocator, diags: *sqlite.vtab.VTabDiagnostics, args: []const []const u8) InitError!*Table {
        _ = diags;
        _ = args;

        var arena = std.heap.ArenaAllocator.init(gpa);
        const allocator = arena.allocator();

        var res = try allocator.create(Table);
        errdefer res.deinit(gpa);

        // Build the schema

        res.schema = try allocator.dupeZ(u8,
            \\CREATE TABLE x(
            \\  commune TEXT,
            \\  code_postal INTEGER,
            \\  code_département INTEGER,
            \\  code_région INTEGER
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

        builder.build();
    }
};

pub const TableCursor = struct {
    allocator: mem.Allocator,
    parent: *Table,
    pos: i64,

    pub const InitError = error{} || mem.Allocator.Error;

    pub fn init(allocator: mem.Allocator, parent: *Table) InitError!*TableCursor {
        var res = try allocator.create(TableCursor);
        res.* = .{
            .allocator = allocator,
            .parent = parent,
            .pos = 0,
        };
        return res;
    }

    const FilterError = error{};

    pub fn filter(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics, index: sqlite.vtab.IndexIdentifier) FilterError!void {
        _ = cursor;
        _ = diags;
        _ = index;
    }

    pub const NextError = error{};

    pub fn next(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics) NextError!void {
        _ = diags;

        cursor.pos += 1;
    }

    pub const HasNextError = error{};

    pub fn hasNext(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics) HasNextError!bool {
        _ = diags;

        return cursor.pos < 20;
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
