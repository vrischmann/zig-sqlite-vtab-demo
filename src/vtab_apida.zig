const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const mem = std.mem;

const sqlite = @import("sqlite");
const c = sqlite.c;

// TODO(vincent): this was an attempt at building a virtual table as a loadable extension but it doesn't work.
// sqlite does some trickery with the C macros SQLITE_EXTENSION_INIT1/SQLITE_EXTENSION_INIT2 which basically
// redefine the exported C API to reference functions on a global variable `sqlite3_api`.
//
// That doesn't work Zig as is, I think we will have to do something equivalent in zig-sqlite's c.zig file.

const Table = struct {
    pub const Cursor = MyCursor;

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
            \\CREATE TABLE foobar(foo TEXT)
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

pub const MyCursor = struct {
    allocator: mem.Allocator,
    parent: *Table,
    pos: i64,

    pub const InitError = error{} || mem.Allocator.Error;

    pub fn init(allocator: mem.Allocator, parent: *Table) InitError!*MyCursor {
        var res = try allocator.create(MyCursor);
        res.* = .{
            .allocator = allocator,
            .parent = parent,
            .pos = 0,
        };
        return res;
    }

    const FilterError = error{} || sqlite.vtab.VTabDiagnostics.SetErrorMessageError;

    pub fn filter(cursor: *MyCursor, diags: *sqlite.vtab.VTabDiagnostics, index: sqlite.vtab.IndexIdentifier) FilterError!void {
        _ = cursor;
        _ = diags;
        _ = index;
    }

    pub const NextError = error{} || sqlite.vtab.VTabDiagnostics.SetErrorMessageError;

    pub fn next(cursor: *MyCursor, diags: *sqlite.vtab.VTabDiagnostics) NextError!void {
        _ = diags;

        cursor.pos += 1;
    }

    pub const HasNextError = error{} || sqlite.vtab.VTabDiagnostics.SetErrorMessageError;

    pub fn hasNext(cursor: *MyCursor, diags: *sqlite.vtab.VTabDiagnostics) HasNextError!bool {
        _ = diags;

        return cursor.pos < 20;
    }

    pub const ColumnError = error{InvalidColumn} || sqlite.vtab.VTabDiagnostics.SetErrorMessageError;

    pub const Column = isize;

    pub fn column(cursor: *MyCursor, diags: *sqlite.vtab.VTabDiagnostics, column_number: i32) ColumnError!Column {
        _ = diags;

        switch (column_number) {
            0 => return cursor.pos * 2,
            else => return error.InvalidColumn,
        }
    }

    pub const RowIDError = error{} || sqlite.vtab.VTabDiagnostics.SetErrorMessageError;

    pub fn rowId(cursor: *MyCursor, diags: *sqlite.vtab.VTabDiagnostics) RowIDError!i64 {
        _ = diags;

        return cursor.pos;
    }
};

const name = "apida";

pub var sqlite3_api: *c.sqlite3_api_routines = undefined;

var module_allocator: std.heap.GeneralPurposeAllocator(.{}) = undefined;
var module_context: sqlite.vtab.ModuleContext = undefined;

pub export fn sqlite3_apida_init(db: *c.sqlite3, err_msg: [*c][*c]u8, api: *c.sqlite3_api_routines) callconv(.C) c_int {
    _ = db;
    _ = err_msg;
    _ = api;

    sqlite3_api = api;

    const VirtualTableType = sqlite.vtab.VirtualTable(name, Table);

    module_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    module_context = sqlite.vtab.ModuleContext{
        .allocator = module_allocator.allocator(),
    };

    const result = sqlite3_api.create_module_v2.?(
        db,
        name,
        &VirtualTableType.module,
        &module_context,
        null,
    );
    return result;
}
