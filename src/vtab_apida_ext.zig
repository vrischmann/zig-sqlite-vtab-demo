const std = @import("std");

const sqlite = @import("sqlite");
const c = sqlite.c;

const apida = @import("vtab_apida.zig");

const name = "apida";

pub const loadable_extension = true;

// TODO(vincent): this was an attempt at building a virtual table as a loadable extension but it doesn't work.
// sqlite does some trickery with the C macros SQLITE_EXTENSION_INIT1/SQLITE_EXTENSION_INIT2 which basically
// redefine the exported C API to reference functions on a global variable `sqlite3_api`.
//
// That doesn't work Zig as is, I think we will have to do something equivalent in zig-sqlite's c.zig file.

var module_allocator: std.heap.GeneralPurposeAllocator(.{}) = undefined;
var module_context: sqlite.vtab.ModuleContext = undefined;

pub export fn sqlite3_apida_init(db: *c.sqlite3, err_msg: [*c][*c]u8, api: *c.sqlite3_api_routines) callconv(.C) c_int {
    _ = err_msg;

    c.sqlite3_api = api;

    const VirtualTableType = sqlite.vtab.VirtualTable(name, apida.Table);

    module_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    module_context = sqlite.vtab.ModuleContext{
        .allocator = module_allocator.allocator(),
    };

    const result = c.sqlite3_create_module_v2(
        db,
        name,
        &VirtualTableType.module,
        &module_context,
        null,
    );
    return result;
}
