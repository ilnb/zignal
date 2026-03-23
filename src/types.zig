const std = @import("std");
const net = std.net;
const Mutex = std.Thread.Mutex;
pub const Set = @import("avl").Set;

pub const Token = struct {
    id: []u8,
    rid: usize,
    name: []u8,
};

pub const Client = struct {
    id: usize,
    conn: net.Server.Connection,
    name: []u8,
    online: bool,
    writer_mutex: Mutex,
    active: std.ArrayList(*Client),
    active_mutex: Mutex,

    pub fn init(c: *Client, conn: *const std.net.Server.Connection, token: *Token) void {
        c.id = token.rid;
        c.conn = conn.*;
        c.name = token.name;
        c.online = true;
        c.writer_mutex = .{};
        c.active = .empty;
        c.active_mutex = .{};
    }
};

pub const State = struct {
    clients: std.ArrayList(*Client),
    links: std.AutoHashMap(usize, Set(usize)),
    mutex: Mutex,
    profile_dir: std.fs.Dir,
    tokens: std.ArrayList(Token),
    ga: std.mem.Allocator,
};
