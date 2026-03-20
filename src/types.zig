const std = @import("std");
const net = std.net;
const Mutex = std.Thread.Mutex;
pub const Set = @import("avl").Set;

pub const Client = struct {
    id: usize,
    conn: net.Server.Connection,
    name: []u8,
    writer_mutex: Mutex,
    active: std.ArrayList(*Client),
    active_mutex: Mutex,
};

pub const Token = struct {
    id: []u8,
    rid: usize,
    name: []u8,
};

pub const State = struct {
    clients: std.ArrayList(*Client),
    links: std.AutoHashMap(usize, Set(usize)),
    mutex: Mutex,
    tokens: std.ArrayList(Token),
    ga: *const std.mem.Allocator,
};
