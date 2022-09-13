const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const mem = std.mem;

const sqlite = @import("sqlite");
const c = @cImport({
    @cInclude("hiredis.h");
});

const Position = @import("main.zig").Position;

const logger = std.log.scoped(.vtab_user);

pub const Table = struct {
    pub const Cursor = TableCursor;

    arena_state: std.heap.ArenaAllocator.State,
    schema: [:0]const u8,

    redis: *c.redisContext,

    pub const InitError = error{
        RedisConnectError,
    } || mem.Allocator.Error || fmt.ParseIntError;

    pub fn init(gpa: mem.Allocator, diags: *sqlite.vtab.VTabDiagnostics, args: []const sqlite.vtab.ModuleArgument) InitError!*Table {
        var arena = std.heap.ArenaAllocator.init(gpa);
        const allocator = arena.allocator();

        var res = try allocator.create(Table);
        errdefer res.deinit(gpa);

        // Parse the arguments
        var host: []const u8 = "localhost";
        var port: c_int = 6379;
        for (args) |arg| {
            switch (arg) {
                .plain => {},
                .kv => |kv| {
                    if (mem.eql(u8, kv.key, "host")) {
                        host = kv.value;
                    } else if (mem.eql(u8, kv.key, "port")) {
                        port = try fmt.parseInt(c_int, kv.value, 10);
                    }
                },
            }
        }

        logger.info("redis: host={s}, port={d}", .{ host, port });

        // Connect to redis
        res.redis = c.redisConnect(try allocator.dupeZ(u8, host), port);
        if (res.redis.err > 0) {
            diags.setErrorMessage("redis connection error: {s}", .{res.redis.errstr});
            return error.RedisConnectError;
        }

        // Build the schema
        res.schema = try allocator.dupeZ(u8,
            \\CREATE TABLE x(
            \\  id TEXT,
            \\  postal_code TEXT,
            \\  name TEXT
            \\)
        );

        res.arena_state = arena.state;

        return res;
    }

    pub fn deinit(table: *Table, gpa: mem.Allocator) void {
        c.redisFree(table.redis);
        table.arena_state.promote(gpa).deinit();
    }

    pub const BuildBestIndexError = error{} || mem.Allocator.Error;

    pub fn buildBestIndex(table: *Table, diags: *sqlite.vtab.VTabDiagnostics, builder: *sqlite.vtab.BestIndexBuilder) BuildBestIndexError!void {
        _ = table;
        _ = diags;

        builder.build();
    }
};

pub const RedisError = error{
    IO,
    EndOfStream,
    Protocol,
    Other,
    ReplyNotAnArray,
    ReplyNotAString,
    ReplyInvalid,
};

pub const TableCursor = struct {
    allocator: mem.Allocator,
    parent: *Table,

    data_arena: std.heap.ArenaAllocator,
    data: []Position,

    redis_scan_reply: *c.redisReply,
    redis_cursor: *c.redisReply,
    redis_array: *c.redisReply,
    redis_array_pos: usize = 0,

    pub const InitError = error{} || mem.Allocator.Error;

    pub fn init(gpa: mem.Allocator, parent: *Table) InitError!*TableCursor {
        var res = try gpa.create(TableCursor);
        res.* = .{
            .allocator = gpa,
            .parent = parent,
            .data_arena = std.heap.ArenaAllocator.init(gpa),
            .data = &[_]Position{},
            .redis_scan_reply = undefined,
            .redis_cursor = undefined,
            .redis_array = undefined,
        };
        return res;
    }

    pub fn deinit(cursor: *TableCursor) void {
        cursor.data_arena.deinit();
        cursor.allocator.destroy(cursor);
    }

    pub const SendScanCommandError = error{} || RedisError || fmt.AllocPrintError;

    fn sendScanCommand(cursor: *TableCursor, allocator: mem.Allocator, diags: *sqlite.vtab.VTabDiagnostics, rcursor: []const u8) SendScanCommandError!void {
        cursor.redis_scan_reply = undefined;
        cursor.redis_cursor = undefined;
        cursor.redis_array = undefined;
        cursor.redis_array_pos = 0;

        //

        const command = try fmt.allocPrintZ(allocator, "SCAN {s} MATCH user:* COUNT 100", .{rcursor});
        defer allocator.free(command);

        if (c.redisCommand(cursor.parent.redis, command)) |reply| {
            // Do some sanity checks
            const redis_reply = @ptrCast(*c.redisReply, @alignCast(@sizeOf(*c.redisReply), reply));
            if (redis_reply.@"type" != c.REDIS_REPLY_ARRAY) {
                diags.setErrorMessage("expected redis reply type \"multi bulk reply\", got {d}", .{redis_reply.@"type"});
                return error.ReplyNotAnArray;
            }
            if (redis_reply.elements != 2) {
                diags.setErrorMessage("expected 2 reply in multi bulk reply for SCAN command, got {d}", .{redis_reply.elements});
                return error.ReplyInvalid;
            }
            if (redis_reply.element[0].*.@"type" != c.REDIS_REPLY_STRING) {
                diags.setErrorMessage("expected first element of reply to be a string, got {d}", .{redis_reply.element[0].*.@"type"});
                return error.ReplyNotAString;
            }
            if (redis_reply.element[1].*.@"type" != c.REDIS_REPLY_ARRAY) {
                diags.setErrorMessage("expected second element of reply to be an array, got {d}", .{redis_reply.element[0].*.@"type"});
                return error.ReplyNotAString;
            }

            // Do not convert the data to Zig-types here, we can easily work with these C types.
            cursor.redis_scan_reply = redis_reply;
            cursor.redis_cursor = redis_reply.element[0];
            cursor.redis_array = redis_reply.element[1];
        } else {
            switch (cursor.parent.redis.err) {
                c.REDIS_ERR_IO => {
                    diags.setErrorMessage("redis I/O error: {s}", .{cursor.parent.redis.errstr});
                    return error.IO;
                },
                c.REDIS_ERR_EOF => {
                    diags.setErrorMessage("redis EOF error: {s}", .{cursor.parent.redis.errstr});
                    return error.EndOfStream;
                },
                c.REDIS_ERR_PROTOCOL => {
                    diags.setErrorMessage("redis protocol parsing error: {s}", .{cursor.parent.redis.errstr});
                    return error.Protocol;
                },
                c.REDIS_ERR_OTHER => {
                    diags.setErrorMessage("redis generic error: {s}", .{cursor.parent.redis.errstr});
                    return error.Other;
                },
                else => unreachable,
            }
            return error.RedisError;
        }
    }

    pub const FilterError = error{} || SendScanCommandError;

    pub fn filter(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics, index: sqlite.vtab.IndexIdentifier, args: []sqlite.vtab.FilterArg) FilterError!void {
        _ = index;
        _ = args;

        cursor.data_arena.deinit();
        const allocator = cursor.data_arena.allocator();

        // Always restart a scan when filter is called
        try cursor.sendScanCommand(allocator, diags, "0");
    }

    pub const NextError = error{} || SendScanCommandError;

    pub fn next(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics) NextError!void {
        _ = diags;
        cursor.redis_array_pos += 1;
    }

    pub const HasNextError = error{} || SendScanCommandError;

    pub fn hasNext(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics) HasNextError!bool {
        const allocator = cursor.data_arena.allocator();

        // Fastpath if there's more to read in the current reply
        if (cursor.redis_array_pos < cursor.redis_array.elements) return true;

        //
        // Here we need to send another SCAN
        //

        while (true) {
            // The previous reply must be freed but we do it _after_ the next SCAN has been done.
            // This is because the rcursor string below still references the SCAN reply data and
            // doing it this way avoids us copying the cursor string.

            const previous_scan_reply = cursor.redis_scan_reply;
            defer c.freeReplyObject(previous_scan_reply);

            const rcursor = cursor.redis_cursor.str[0..cursor.redis_cursor.len];

            // No more elements, check if we scan more data
            if (mem.eql(u8, rcursor, "0")) return false;

            // The cursor is valid, continue the scan
            try cursor.sendScanCommand(allocator, diags, rcursor);

            if (cursor.redis_array.elements > 0) return true;
        }
    }

    const HGetError = error{} || RedisError || fmt.AllocPrintError;

    fn hget(cursor: *TableCursor, allocator: mem.Allocator, diags: *sqlite.vtab.VTabDiagnostics, key: []const u8, field: []const u8) HGetError![]const u8 {
        const command = try fmt.allocPrintZ(allocator, "HGET {s} {s}", .{ key, field });
        defer allocator.free(command);

        if (c.redisCommand(cursor.parent.redis, command)) |reply| {
            // Do some sanity checks
            const redis_reply = @ptrCast(*c.redisReply, @alignCast(@sizeOf(*c.redisReply), reply));
            if (redis_reply.@"type" != c.REDIS_REPLY_STRING) {
                diags.setErrorMessage("expected redis reply type \"string\", got {d}", .{redis_reply.@"type"});
                return error.ReplyNotAnArray;
            }

            return redis_reply.str[0..redis_reply.len];
        } else {
            switch (cursor.parent.redis.err) {
                c.REDIS_ERR_IO => {
                    diags.setErrorMessage("redis I/O error: {s}", .{cursor.parent.redis.errstr});
                    return error.IO;
                },
                c.REDIS_ERR_EOF => {
                    diags.setErrorMessage("redis EOF error: {s}", .{cursor.parent.redis.errstr});
                    return error.EndOfStream;
                },
                c.REDIS_ERR_PROTOCOL => {
                    diags.setErrorMessage("redis protocol parsing error: {s}", .{cursor.parent.redis.errstr});
                    return error.Protocol;
                },
                c.REDIS_ERR_OTHER => {
                    diags.setErrorMessage("redis generic error: {s}", .{cursor.parent.redis.errstr});
                    return error.Other;
                },
                else => unreachable,
            }
            return error.RedisError;
        }
    }

    pub const ColumnError = error{InvalidColumn} || HGetError;

    pub const Column = union(enum) {
        id: []const u8,
        postal_code: []const u8,
        name: []const u8,
    };

    pub fn column(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics, column_number: i32) ColumnError!Column {
        const allocator = cursor.data_arena.allocator();

        const entry = cursor.redis_array.element[cursor.redis_array_pos].*;
        const id = entry.str[0..entry.len];

        switch (column_number) {
            0 => return Column{ .id = id },
            1 => {
                const postal_code = try cursor.hget(allocator, diags, id, "postal_code");
                return Column{ .postal_code = postal_code };
            },
            2 => {
                const name = try cursor.hget(allocator, diags, id, "name");
                return Column{ .name = name };
            },
            else => {
                diags.setErrorMessage("column number {d} is invalid", .{column_number});
                return error.InvalidColumn;
            },
        }
    }

    pub const RowIDError = error{};

    pub fn rowId(cursor: *TableCursor, diags: *sqlite.vtab.VTabDiagnostics) RowIDError!i64 {
        _ = diags;

        return @intCast(i64, cursor.redis_array_pos);
    }
};
