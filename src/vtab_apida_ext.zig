const std = @import("std");

const sqlite = @import("sqlite");
const c = sqlite.c;

const curl = @import("curl.zig");
const apida = @import("vtab_apida.zig");

const name = "apida";

pub const loadable_extension = true;

var module_allocator: std.heap.GeneralPurposeAllocator(.{}) = undefined;
var module_context: sqlite.vtab.ModuleContext = undefined;

pub export fn sqlite3_apida_init(db: *c.sqlite3, err_msg: [*c][*c]u8, api: *c.sqlite3_api_routines) callconv(.C) c_int {
    _ = err_msg;

    c.sqlite3_api = api;

    curl.globalInit();
    defer curl.globalCleanup();

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
