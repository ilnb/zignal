const std = @import("std");
const net = std.Io.net;
const Mutex = std.Io.Mutex;
const Writer = std.Io.Writer;
const info = std.log.info;

pub const Set = @import("avl").Set;

pub const Token = struct {
    id: []u8,
    rid: ?usize = null,
    name: []u8,
};

pub const UiState = struct {
    mutex: Mutex = .init,
    cond: std.Io.Condition = .init,
    prompt_vis: bool = false,
    pending: bool = false,
};

pub const Client = struct {
    rid: usize,
    conn: net.Stream,
    name: []u8,
    online: bool = true,
    writer_mutex: Mutex = .init,
    active: std.ArrayList(*Client) = .empty,
    active_mutex: Mutex = .init,

    pub fn init(c: *Client, conn: *const net.Stream, token: *Token) void {
        c.* = .{
            .rid = token.rid.?,
            .conn = conn.*,
            .name = token.name,
            .online = true,
            .writer_mutex = .init,
            .active = .empty,
            .active_mutex = .init,
        };
    }

    pub fn errWrite(c: *Client, w: *Writer, comptime fmt: []const u8, args: anytype) ?void {
        w.print(fmt, args) catch |err| {
            info("Write failed to {d}: {any}", .{ c.rid, err });
            return null;
        };
    }

    pub fn errWriteAll(c: *Client, w: *Writer, msg: []const u8) ?void {
        w.writeAll(msg) catch |err| {
            info("Write failed to {d}: {any}", .{ c.rid, err });
            return null;
        };
    }

    pub fn errFlush(c: *Client, w: *Writer) ?void {
        w.flush() catch |err| {
            info("Flush failed to {d}: {any}", .{ c.rid, err });
            return null;
        };
    }
};

pub const State = struct {
    clients: std.ArrayList(*Client),
    links: std.AutoHashMap(usize, Set(usize)),
    mutex: Mutex,
    profile_dir: std.Io.Dir,
    tokens: std.ArrayList(Token),
    ga: std.mem.Allocator,
    io: std.Io,
};
