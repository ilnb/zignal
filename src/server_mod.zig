pub fn handleClient(client: *Client, state: *State) !void {
    // defer cleanupClient(client, state) catch {};
    defer client.online = false;
    const conn = client.conn;
    info("Accepted connection from {f}, {d}", .{ conn.socket.address, client.rid });

    var read_buf: [1024]u8 = undefined;
    var reader_file = conn.reader(state.io, &read_buf);
    const r = &reader_file.interface;

    while (true) {
        info("Waiting for data from {d}...", .{client.rid});
        const slen = r.takeDelimiter(' ') catch |err| {
            info("Read failed from {d}: {any}", .{ client.rid, err });
            break;
        } orelse {
            info("Connection closed by client {d}", .{client.rid});
            break;
        };
        const len = try std.fmt.parseInt(usize, slen, 10);

        const msg = r.readAlloc(state.aa, len) catch |err| {
            switch (err) {
                error.OutOfMemory => {
                    info("OOM while reading message from {d}", .{client.rid});
                },
                else => {
                    info("Read failed from {d}: {any}", .{ client.rid, err });
                },
            }
            break;
        };
        defer state.aa.free(msg);

        info("{d} says {s}", .{ client.rid, msg });
        parseHeaderAndAct(client, msg, state) catch |err| {
            info("Closing client {d} due to error: {any}", .{ client.rid, err });
            return;
        };
    }
}

fn parseHeaderAndAct(client: *Client, msg: []const u8, state: *State) !void {
    const io = state.io;
    const aa = state.aa;
    const parsed_pkt = try std.json.parseFromSlice(Packet, aa, msg, .{});
    const parsed_value = parsed_pkt.value;
    defer parsed_pkt.deinit();

    var buf: [1024]u8 = undefined;
    var writer = client.conn.writer(io, &buf);
    const w = &writer.interface;

    switch (parsed_value.data) {
        .echo => {
            try client.writer_mutex.lock(io);
            defer client.writer_mutex.unlock(io);
            client.errWriteAll(w, msg) orelse return;
            client.errFlush(w) orelse return;
        },
        .name => |name| {
            try state.mutex.lock(io);
            defer state.mutex.unlock(io);
            const token: *Token = for (state.tokens.items) |*t| {
                if (t.rid) |rid| if (rid == client.rid) break t;
            } else {
                info("Corrupted tokens list. Client with {d} not found.", .{client.rid});
                try client.sendData(w, Data{
                    .err = "ERR: Corrupted tokens list on server. Client not found.",
                }) orelse return;
                return;
            };
            state.ga.free(token.name);
            token.name = state.ga.dupe(u8, name) catch |err| {
                info("Failed to set name for {d}: {any}", .{ client.rid, err });
                const e = try allocPrint(aa, "ERR: Failed to set name: {any}", .{err});
                defer aa.free(e);
                try client.writer_mutex.lock(io);
                defer client.writer_mutex.unlock(io);
                try client.sendData(w, Data{ .err = e }) orelse return;
                return;
            };
            client.name = token.name;
            info("Named {d} -> {s}", .{ client.rid, name });
            try client.writer_mutex.lock(io);
            defer client.writer_mutex.unlock(io);
            try client.sendData(w, parsed_value.data) orelse return;
        },
        .link => |p| {
            try state.mutex.lock(io);
            defer state.mutex.unlock(io);
            const i = getClientById(state, p.with) orelse getClientByName(state, p.with) orelse {
                const e = try allocPrint(aa, "ERR: Failed to link to {s}. Invalid id or name.", .{p.with});
                defer aa.free(e);
                try client.writer_mutex.lock(io);
                defer client.writer_mutex.unlock(io);
                try client.sendData(w, Data{ .err = e }) orelse return;
                return;
            };
            const c2 = state.clients.items[i];
            if (!p.invert) {
                try linkClients(client, c2, state);
            } else {
                try unlinkClients(client, c2, state);
            }
            try client.writer_mutex.lock(io);
            defer client.writer_mutex.unlock(io);
            client.errWriteAll(w, "") orelse return;
            client.errFlush(w) orelse return;
        },
        .msg => |p| {
            if (p.peer) |ibuf| {
                try state.mutex.lock(io);
                defer state.mutex.unlock(io);
                const i = getClientById(state, ibuf) orelse getClientByName(state, ibuf) orelse {
                    const e = try allocPrint(aa, "ERR: Failed to send message to {s}. Invalid id or name.", .{p.buf});
                    defer aa.free(e);
                    try client.writer_mutex.lock(io);
                    defer client.writer_mutex.unlock(io);
                    try client.sendData(w, Data{ .err = e }) orelse return;
                    return;
                };
                const c = state.clients.items[i];
                if (state.links.getPtr(client.rid).?.contains(c.rid) == null) {
                    const e = try allocPrint(aa, "ERR: Not connected to {d}.", .{c.rid});
                    defer aa.free(e);
                    try client.writer_mutex.lock(io);
                    defer client.writer_mutex.unlock(io);
                    try client.sendData(w, Data{ .err = e }) orelse return;
                    return;
                }
                var cw_file = c.conn.writer(io, &buf);
                const cw = &cw_file.interface;
                const peer = try allocPrint(aa, "{s} {d}", .{ client.name, client.rid });
                defer aa.free(peer);
                try c.writer_mutex.lock(io);
                defer c.writer_mutex.unlock(io);
                try c.sendData(cw, Data{
                    .msg = .{
                        .peer = peer,
                        .buf = p.buf,
                    },
                }) orelse return;
            } else {
                try client.active_mutex.lock(io);
                defer client.active_mutex.unlock(io);
                for (client.active.items) |c| {
                    if (client.rid != c.rid) {
                        @branchHint(.likely);
                        var cw_file = c.conn.writer(io, &buf);
                        const cw = &cw_file.interface;
                        const peer = try allocPrint(aa, "{s} {d}", .{ client.name, client.rid });
                        defer aa.free(peer);
                        try c.writer_mutex.lock(io);
                        defer c.writer_mutex.unlock(io);
                        try c.sendData(cw, Data{
                            .msg = .{
                                .peer = peer,
                                .buf = p.buf,
                            },
                        }) orelse continue;
                    }
                }
            }
            try client.writer_mutex.lock(io);
            defer client.writer_mutex.unlock(io);
            client.errWriteAll(w, "") orelse return;
            client.errFlush(w) orelse return;
        },
        .to_get => |p| {
            try state.mutex.lock(io);
            var arr: std.ArrayList(Packet.Infos) = try .initCapacity(aa, p.len);
            errdefer arr.deinit(aa);
            if (p.len != 0) {
                for (p) |c2| {
                    const i = getClientById(state, c2) orelse getClientByName(state, c2) orelse {
                        const e = try allocPrint(aa, "ERR: Failed to getinfo of {s}. Invalid id or name.", .{c2});
                        defer aa.free(e);
                        try client.writer_mutex.lock(io);
                        defer client.writer_mutex.unlock(io);
                        try client.sendData(w, Data{ .err = e }) orelse continue;
                        continue;
                    };
                    try arr.append(aa, try getInfo(state.clients.items[i], state));
                }
            } else {
                for (state.clients.items) |c| {
                    try arr.append(aa, try getInfo(c, state));
                }
            }
            state.mutex.unlock(io);
            const users = try arr.toOwnedSlice(aa);
            defer {
                for (users) |*u| aa.free(u.links);
                aa.free(users);
            }
            try client.writer_mutex.lock(io);
            defer client.writer_mutex.unlock(io);
            try client.sendData(w, Data{
                .users = users,
            }) orelse return;
        },
        .err => |p| {
            try client.writer_mutex.lock(io);
            defer client.writer_mutex.unlock(io);
            try client.sendData(w, Data{ .err = p }) orelse return;
        },
        .init, .new_user, .users => {},
    }
}

inline fn getInfo(c: *Client, state: *State) !Packet.Infos {
    const links = state.links.getPtr(c.rid).?;
    var itr = links.iterator();
    var links_arr: std.ArrayList(usize) = try .initCapacity(state.aa, links.count);
    while (itr.next()) |n| try links_arr.append(state.aa, n.key);

    return .{
        .rid = c.rid,
        .name = c.name,
        .links = try links_arr.toOwnedSlice(state.aa),
    };
}

fn linkClients(client1: *Client, client2: *Client, state: *State) !void {
    const id1 = client1.rid;
    const id2 = client2.rid;
    const links = &state.links;

    const f = links.getPtr(id1) orelse {
        info("Invalid id {d}", .{id1});
        return;
    };
    const s = links.getPtr(id2) orelse {
        info("Invalid id {d}", .{id2});
        return;
    };

    if (f.contains(id2) != null) return;
    f.put(id2) catch |err| {
        info("Error when connecting {d}: {any}", .{ id1, err });
        return;
    };
    s.put(id1) catch |err| {
        info("Error when connecting {d}: {any}", .{ id2, err });
        return;
    };

    const io = state.io;
    try client1.active_mutex.lock(io);
    defer client1.active_mutex.unlock(io);
    client1.active.append(state.ga, client2) catch |err| {
        info("Error appending active {any}", .{err});
        return;
    };

    try client2.active_mutex.lock(io);
    defer client2.active_mutex.unlock(io);
    client2.active.append(state.ga, client1) catch |err| {
        info("Error appending active {any}", .{err});
        return;
    };

    info("Connected {d} and {d}", .{ id1, id2 });
}

fn unlinkClients(client1: *Client, client2: *Client, state: *State) !void {
    if (client1 == client2) return;
    const id1 = client1.rid;
    const id2 = client2.rid;
    const links = &state.links;

    const f = links.getPtr(id1) orelse {
        info("Invalid id {d}", .{id1});
        return;
    };
    const s = links.getPtr(id2) orelse {
        info("Invalid id {d}", .{id2});
        return;
    };

    if (f.contains(id2) == null) return;
    f.remove(id2);
    s.remove(id1);

    const io = state.io;
    try client1.active_mutex.lock(io);
    defer client1.active_mutex.unlock(io);
    for (client1.active.items, 0..) |c, i| {
        if (c == client2) {
            _ = client1.active.swapRemove(i);
            break;
        }
    }

    try client2.active_mutex.lock(io);
    defer client2.active_mutex.unlock(io);
    for (client2.active.items, 0..) |c, i| {
        if (c == client1) {
            _ = client2.active.swapRemove(i);
            break;
        }
    }

    info("Disconnected {d} and {d}", .{ id1, id2 });
}

fn cleanupClient(client: *Client, state: *State) !void {
    const io = state.io;
    const id = client.rid;
    try state.mutex.lock(io);
    defer state.mutex.unlock(io);

    const clients = &state.clients;
    for (clients.items, 0..) |c, i| {
        if (c == client) {
            _ = clients.swapRemove(i);
            break;
        }
    } else {
        info("Client not found in the clients list", .{});
    }

    const links = &state.links;
    for (clients.items) |c| {
        if (c.rid != client.rid) links.getPtr(c.rid).?.remove(id);
        try c.active_mutex.lock(io);
        defer c.active_mutex.unlock(io);
        for (c.active.items, 0..) |c_, i| {
            if (c_.rid == id) {
                _ = c.active.swapRemove(i);
                break;
            }
        }
    }

    client.active.deinit(state.ga);
    client.conn.close(io);
    state.ga.destroy(client);
}

pub const HandshakeResult = union(enum) {
    new: Token,
    existing: usize,
};

pub fn handshakeWithClient(conn: net.Stream, state: *State) !HandshakeResult {
    var buf: [128]u8 = undefined;
    var reader_file = conn.reader(state.io, buf[0..64]);
    const reader = &reader_file.interface;
    var writer_file = conn.writer(state.io, buf[64..]);
    const writer = &writer_file.interface;
    const msg = try reader.takeDelimiter('\n') orelse return error.EmptyMessage;
    info("Recieved handshake message {s} from client {f}", .{ msg, conn.socket.address });

    var itr = std.mem.tokenizeAny(u8, msg, " \n");
    const new_or_old = itr.next() orelse return error.BadHandshake;
    const token_id = itr.next() orelse return error.BadHandshake;

    const idx: ?usize = for (state.tokens.items, 0..) |t, i| {
        if (std.mem.eql(u8, t.id, token_id)) break i;
    } else null;

    if (idx != null) {
        if (std.mem.eql(u8, new_or_old, "NEW")) return error.KnownClient;
        try writer.writeAll("2 OK");
        try writer.flush();
        return .{ .existing = idx.? };
    } else {
        if (std.mem.eql(u8, new_or_old, "OLD")) return error.UnknownClient;
        try writer.writeAll("2 OK");
        try writer.flush();
        return .{ .new = Token{ .id = try state.ga.dupe(u8, token_id), .name = try state.ga.dupe(u8, "NA") } };
    }
}

const std = @import("std");
const eql = std.mem.eql;
const info = std.log.info;
const net = std.Io.net;
const types = @import("types");
const State = types.Server;
const Client = State.SClient;
const Token = types.Token;
const Packet = types.Packet;
const PacketType = types.PacketType;
const Data = Packet.Data;
const utils = @import("utils");
const bufPrint = std.fmt.bufPrint;
const allocPrint = std.fmt.allocPrint;
const getClientById = utils.getClientById;
const getClientByName = utils.getClientByName;
const Stringify = std.json.Stringify;
const valueAlloc = Stringify.valueAlloc;
