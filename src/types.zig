const std = @import("std");
const net = std.Io.net;
const Mutex = std.Io.Mutex;
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
        c.rid = token.rid.?;
        c.conn = conn.*;
        c.name = token.name;
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
