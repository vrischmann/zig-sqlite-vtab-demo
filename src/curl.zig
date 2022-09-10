const std = @import("std");
const mem = std.mem;
const log = std.log;

const c = @cImport({
    @cInclude("curl/curl.h");
});

const user_agent = "User-Agent: Mozilla/5.0 (X11; Fedora; Linux x86_64; rv:83.0) Gecko/20100101 Firefox/83.0";

pub fn globalInit() void {
    _ = c.curl_global_init(c.CURL_GLOBAL_ALL);
}

pub fn globalCleanup() void {
    _ = c.curl_global_cleanup();
}

pub const Response = struct {
    status: usize,
    headers: []const []const u8,
    body: []const u8,
};

const TemporaryResponse = struct {
    const Self = @This();

    allocator: mem.Allocator,

    body: std.ArrayList(u8),
    headers: std.ArrayList([]const u8),

    fn appendHeader(self: *Self, data: []const u8) !void {
        const header = try self.allocator.dupeZ(
            u8,
            mem.trim(u8, data, "\r\n"),
        );
        if (header.len == 0) return;

        try self.headers.append(header);
    }
};

pub const Error = error{
    CannotInitialize,
    RequestFailed,
};

pub const Client = struct {
    const Self = @This();

    curl: *c.CURL,

    pub fn init() !Self {
        var res: Self = undefined;
        res.curl = if (c.curl_easy_init()) |curl| curl else return error.CannotInitialize;

        return res;
    }

    pub fn deinit(self: *Self) void {
        c.curl_easy_cleanup(self.curl);
    }

    pub fn get(self: *Self, allocator: mem.Allocator, url: [:0]const u8) Error!Response {
        c.curl_easy_reset(self.curl);

        // Build the the response
        var resp: Response = undefined;

        var tmp: TemporaryResponse = undefined;
        tmp.allocator = allocator;
        tmp.body = std.ArrayList(u8).init(allocator);
        tmp.headers = std.ArrayList([]const u8).init(allocator);

        // Setup the URL
        _ = c.curl_easy_setopt(self.curl, c.CURLOPT_URL, @ptrCast([*:0]const u8, url));

        _ = c.curl_easy_setopt(self.curl, c.CURLOPT_USERAGENT, @ptrCast([*:0]const u8, user_agent));

        // Setup the write and read callback
        _ = c.curl_easy_setopt(self.curl, c.CURLOPT_WRITEFUNCTION, writeCallback);
        _ = c.curl_easy_setopt(self.curl, c.CURLOPT_WRITEDATA, &tmp);

        _ = c.curl_easy_setopt(self.curl, c.CURLOPT_HEADERFUNCTION, headerCallback);
        _ = c.curl_easy_setopt(self.curl, c.CURLOPT_HEADERDATA, &tmp);

        _ = c.curl_easy_setopt(self.curl, c.CURLOPT_HTTPGET, @as(c_int, 1));

        // Send request
        const res = c.curl_easy_perform(self.curl);
        if (res != c.CURLE_OK) {
            std.log.warn("curl_easy_perform failed: {s}", .{c.curl_easy_strerror(res)});
            return error.RequestFailed;
        }

        // Create response

        var status: c_long = 0;
        _ = c.curl_easy_getinfo(self.curl, c.CURLINFO_RESPONSE_CODE, &status);
        resp.status = @intCast(usize, status);

        resp.body = tmp.body.toOwnedSlice();
        resp.headers = tmp.headers.toOwnedSlice();

        return resp;
    }
};

fn writeCallback(data: [*]u8, _: c_int, nmemb: usize, response: *TemporaryResponse) usize {
    response.body.appendSlice(data[0..nmemb]) catch |err| {
        std.debug.panic("unable to write data in temporary body because of error {}", .{err});
    };
    return nmemb;
}

fn headerCallback(data: [*]u8, _: c_int, nmemb: usize, response: *TemporaryResponse) usize {
    response.appendHeader(data[0..nmemb]) catch |err| {
        std.debug.panic("unable to append header because of error {}", .{err});
    };
    return nmemb;
}
