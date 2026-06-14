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

        const line = r.readAlloc(state.aa, len) catch |err| {
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
        defer state.aa.free(line);

        const trimmed = std.mem.trim(u8, line, " ");
        if (trimmed.len == 0) continue;
        info("{d} says {s}", .{ client.rid, trimmed });
        try parseHeaderAndAct(client, trimmed, state);
    }
}

fn parseHeaderAndAct(client: *Client, msg: []const u8, state: *State) !void {
    const io = state.io;
    var pkt = try parsePacket(client, msg, state);
    var buf: [1024]u8 = undefined;
    var writer = client.conn.writer(io, &buf);
    const w = &writer.interface;

    switch (pkt.data) {
        .echo,
        .init,
        => {
            const res = try valueAlloc(state.aa, pkt, .{ .whitespace = .indent_2 });
            defer state.aa.free(res);
            client.errWriteAll(w, res) orelse return;
            client.errFlush(w) orelse return;
        },
        .link => |p| {
            try state.mutex.lock(io);
            defer state.mutex.unlock(io);
            const c2 = state.clients.items[p.with];
            if (!p.invert) {
                try linkClients(client, c2, state);
            } else {
                try unlinkClients(client, c2, state);
            }
            client.errWriteAll(w, "") orelse return;
            client.errFlush(w) orelse return;
        },
        .msg => |p| {
            try state.mutex.lock(io);
            defer state.mutex.unlock(io);
            defer state.aa.free(p.buf);
            if (p.to) |i| {
                const c2 = state.clients.items[i];
                try sendMsg(state.io, client, c2, p.buf);
            } else {
                try sendAll(state.io, client, p.buf);
            }
            client.errWriteAll(w, "") orelse return;
            client.errFlush(w) orelse return;
        },
        .to_get => |*p| {
            try state.mutex.lock(io);
            defer state.mutex.unlock(io);
            if (p.items.len != 0) {
                defer p.deinit(state.aa);
                for (p.items) |c2| {
                    try displayClient(client, state.clients.items[c2], state);
                }
            } else {
                try displayAll(client, state);
            }
        },
        .err => |p| {
            try state.mutex.lock(io);
            defer state.mutex.unlock(io);
            defer state.aa.free(p);
            const res = try valueAlloc(state.aa, pkt, .{ .whitespace = .indent_2 });
            defer state.aa.free(res);
            client.errWriteAll(w, res) orelse return;
            client.errFlush(w) orelse return;
        },
        .name, .new_user, .users => {},
    }
}

fn parsePacket(client: *Client, msg: []const u8, state: *State) !Packet {
    const io = state.io;
    var itr = std.mem.tokenizeScalar(u8, msg, ' ');

    const header = itr.next() orelse return Packet{
        .rid = client.rid,
        .data = .{ .echo = "" },
    };
    if (eql(u8, header, "ECHO")) {
        const to_echo = itr.rest();
        return Packet{
            .rid = client.rid,
            .data = .{
                .echo = to_echo,
            },
        };
    } else if (eql(u8, header, "WHOAMI")) {
        return Packet{
            .rid = client.rid,
            .data = .{
                .name = client.name,
            },
        };
    } else if (eql(u8, header, "NAME")) {
        const name = itr.next() orelse return Packet{
            .rid = client.rid,
            .data = .{
                .err = try state.aa.dupe(u8, "No id or name specified."),
            },
        };
        var num_count: usize = 0;
        for (name) |c| {
            if (c >= '0' and c <= '9') num_count += 1;
        }
        if (num_count == name.len) return Packet{
            .rid = client.rid,
            .data = .{
                .err = try state.aa.dupe(u8, "All numeric name is not allowed."),
            },
        };
        try state.mutex.lock(io);
        const token: *Token = for (state.tokens.items) |*t| {
            if (t.rid) |rid| if (rid == client.rid) break t;
        } else {
            info("Corrupted tokens list. Client with {d} not found.", .{client.rid});
            return Packet{
                .rid = client.rid,
                .data = .{ .echo = "" },
            };
        };
        state.mutex.unlock(io);
        state.ga.free(token.name);
        token.name = state.ga.dupe(u8, name) catch |err| {
            info("Failed to set name for {d}: {any}", .{ client.rid, err });
            return Packet{
                .rid = client.rid,
                .data = .{
                    .err = try allocPrint(state.aa, "Failed to set name: {any}", .{err}),
                },
            };
        };
        client.name = token.name;
        info("Named {d} -> {s}", .{ client.rid, name });
        return Packet{
            .rid = client.rid,
            .data = .{ .echo = "" },
        };
    } else if (eql(u8, header, "LINK")) {
        const buf = itr.next() orelse return Packet{
            .rid = client.rid,
            .data = .{
                .err = try state.aa.dupe(u8, "No id or name specified."),
            },
        };
        try state.mutex.lock(io);
        const c2 = getClientById(state, buf) orelse getClientByName(state, buf) orelse return Packet{
            .rid = client.rid,
            .data = .{
                .err = try allocPrint(state.ga, "Failed to connect to {s}. Invalid id or name.", .{buf}),
            },
        };
        state.mutex.unlock(io);
        if (client.rid == c2) return Packet{
            .rid = client.rid,
            .data = .{
                .err = try state.aa.dupe(u8, "Self link."),
            },
        };
        return Packet{
            .rid = client.rid,
            .data = .{
                .link = .{
                    .with = c2,
                },
            },
        };
    } else if (eql(u8, header, "UNLINK")) {
        const buf = itr.next() orelse return Packet{
            .rid = client.rid,
            .data = .{
                .err = try state.aa.dupe(u8, "No id or name specified."),
            },
        };
        try state.mutex.lock(io);
        const c2 = getClientById(state, buf) orelse getClientByName(state, buf) orelse return Packet{
            .rid = client.rid,
            .data = .{
                .err = try allocPrint(state.aa, "Failed to unlink from {s}. Invalid id or name.", .{buf}),
            },
        };
        state.mutex.unlock(io);
        if (client.rid == c2) return Packet{
            .rid = client.rid,
            .data = .{
                .err = try state.aa.dupe(u8, "Self unlink."),
            },
        };
        return Packet{
            .rid = client.rid,
            .data = .{
                .link = .{
                    .with = c2,
                    .invert = true,
                },
            },
        };
    } else if (eql(u8, header, "SENDTO")) {
        const buf = itr.next() orelse return Packet{
            .rid = client.rid,
            .data = .{
                .err = try state.aa.dupe(u8, "No id or name specified."),
            },
        };
        const to_send = std.mem.trim(u8, itr.rest(), " \n");
        try state.mutex.lock(io);
        const c2 = getClientById(state, buf) orelse getClientByName(state, buf) orelse return Packet{
            .rid = client.rid,
            .data = .{
                .err = try allocPrint(state.aa, "Failed to send message to {s}. Invalid id or name.", .{buf}),
            },
        };
        state.mutex.unlock(io);
        return Packet{
            .rid = client.rid,
            .data = .{
                .msg = .{
                    .to = c2,
                    .buf = try state.aa.dupe(u8, to_send),
                },
            },
        };
    } else if (eql(u8, header, "ALL")) {
        const to_send = std.mem.trim(u8, itr.rest(), " \n");
        return Packet{
            .rid = client.rid,
            .data = .{
                .msg = .{
                    .buf = try state.aa.dupe(u8, to_send),
                },
            },
        };
    } else if (eql(u8, header, "GETINFO")) {
        const buf = itr.next() orelse return Packet{
            .rid = client.rid,
            .data = .{
                .to_get = .empty,
            },
        };
        try state.mutex.lock(io);
        const to_fetch = getClientById(state, buf) orelse getClientByName(state, buf) orelse return Packet{
            .rid = client.rid,
            .data = .{
                .err = try allocPrint(state.aa, "Failed to getinfo of {s}. Invalid id or name.", .{buf}),
            },
        };
        state.mutex.unlock(io);
        var arr: std.ArrayList(usize) = .empty;
        try arr.append(state.aa, to_fetch);
        return Packet{
            .rid = client.rid,
            .data = .{
                .to_get = arr,
            },
        };
    } else return Packet{
        .rid = client.rid,
        .data = .{
            .err = try allocPrint(state.aa, "Invalid cmd {s}.", .{header}),
        },
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

fn sendMsg(io: std.Io, from: *Client, to: *Client, to_send: []const u8) !void {
    var buf: [1024]u8 = undefined;

    const err_msg: ?[]const u8 = if (!to.online)
        bufPrint(&buf, "Client {d} is offline.", .{to.rid}) catch "Specified client is offline."
    else if (from == to)
        "Self message."
    else if (to_send.len == 0)
        "Empty message."
    else
        null;

    if (err_msg != null) {
        try from.writer_mutex.lock(io);
        defer from.writer_mutex.unlock(io);
        var writer = from.conn.writer(io, &buf);
        const w = &writer.interface;
        from.errWrite(w, "ERR: {s}", .{err_msg.?}) orelse return;
        from.errFlush(w) orelse return;
        return;
    }

    try from.active_mutex.lock(io);
    defer from.active_mutex.unlock(io);
    _ = for (from.active.items) |c| {
        if (c == to) break c;
    } else {
        try from.writer_mutex.lock(io);
        defer from.writer_mutex.unlock(io);
        var writer = from.conn.writer(io, &buf);
        const w = &writer.interface;
        from.errWrite(w, "ERR: Not connected to {s}.", .{to.name}) orelse return;
        from.errFlush(w) orelse return;
        return;
    };

    try to.active_mutex.lock(io);
    defer to.active_mutex.unlock(io);
    _ = for (to.active.items) |c| {
        if (c == from) break c;
    } else {
        try to.writer_mutex.lock(io);
        defer to.writer_mutex.unlock(io);
        var writer = to.conn.writer(io, &buf);
        const w = &writer.interface;
        to.errWrite(w, "ERR: Not connected to {s}.", .{from.name}) orelse return;
        to.errFlush(w) orelse return;
        return;
    };

    try to.writer_mutex.lock(io);
    defer to.writer_mutex.unlock(io);
    var writer = to.conn.writer(io, &buf);
    const w = &writer.interface;
    to.errWrite(w, "({s}, {d}): {s}", .{ from.name, from.rid, to_send }) orelse return;
    to.errFlush(w) orelse return;
}

fn sendAll(io: std.Io, from: *Client, to_send: []const u8) !void {
    if (to_send.len == 0) return;
    var buf: [1024]u8 = undefined;
    try from.active_mutex.lock(io);
    defer from.active_mutex.unlock(io);
    for (from.active.items) |c| {
        if (!c.online) continue;
        try c.writer_mutex.lock(io);
        defer c.writer_mutex.unlock(io);
        var writer = c.conn.writer(io, &buf);
        const w = &writer.interface;
        c.errWrite(w, "({s}, {d}): {s}", .{ from.name, from.rid, to_send }) orelse return;
        c.errFlush(w) orelse return;
    }
}

fn displayClient(client: *Client, to_fetch: *Client, state: *State) !void {
    const io = state.io;
    var id_w: usize, var name_w: usize = .{ 0, "NAME".len };
    for (state.clients.items) |c| {
        if (!c.online) continue;
        id_w = @max(id_w, std.fmt.count("{d}", .{c.rid}));
        name_w = @max(name_w, c.name.len);
    }
    id_w += 2;
    if (name_w == "NAME".len) name_w += 1;
    name_w += 2;

    const ga = client.ga;
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(ga);

    var res = try allocPrint(ga, "{s: <[2]}{s: <[3]}LINK\n", .{ "ID", "NAME", id_w, name_w });
    try msg.appendSlice(ga, res);
    ga.free(res);

    var name_buf: [256]u8 = undefined;
    const name = if (to_fetch.rid == client.rid)
        std.fmt.bufPrint(&name_buf, "{s}*", .{to_fetch.name}) catch to_fetch.name
    else
        to_fetch.name;
    res = try allocPrint(ga, "{d: <[2]}{s: <[3]}", .{ to_fetch.rid, name, id_w, name_w });
    try msg.appendSlice(ga, res);
    ga.free(res);

    const conns = state.links.getPtr(to_fetch.rid).?;
    var itr = conns.iterator();
    var i: usize = 1;
    while (itr.next()) |node| {
        res = try allocPrint(ga, "{d}{s}", .{ node.key, if (i != conns.count) ", " else "" });
        try msg.appendSlice(ga, res);
        ga.free(res);
        i += 1;
    }

    var write_buf: [1024]u8 = undefined;
    try client.writer_mutex.lock(io);
    defer client.writer_mutex.unlock(io);
    var writer = client.conn.writer(io, &write_buf);
    const w = &writer.interface;
    client.errWriteAll(w, msg.items) orelse return;
    client.errFlush(w) orelse return;
}

fn displayAll(client: *Client, state: *State) !void {
    const io = state.io;
    var id_w: usize, var name_w: usize = .{ 0, "NAME".len };
    for (state.clients.items) |c| {
        if (!c.online) continue;
        id_w = @max(id_w, std.fmt.count("{d}", .{c.rid}));
        name_w = @max(name_w, c.name.len);
    }
    id_w += 2;
    if (name_w == "NAME".len) name_w += 1;
    name_w += 2;

    const ga = client.ga;
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(ga);

    var res = try allocPrint(ga, "{s: <[2]}{s: <[3]}LINK\n", .{ "ID", "NAME", id_w, name_w });
    try msg.appendSlice(ga, res);
    ga.free(res);

    for (state.clients.items) |c| {
        var name_buf: [256]u8 = undefined;
        const name = if (c.rid == client.rid)
            std.fmt.bufPrint(&name_buf, "{s}*", .{c.name}) catch c.name
        else
            c.name;
        res = try allocPrint(ga, "{d: <[2]}{s: <[3]}", .{ c.rid, name, id_w, name_w });
        try msg.appendSlice(ga, res);
        ga.free(res);

        const conns = state.links.getPtr(c.rid).?;
        var itr = conns.iterator();
        var i: usize = 1;
        while (itr.next()) |node| {
            res = try allocPrint(ga, "{d}{s}", .{ node.key, if (i != conns.count) ", " else "" });
            try msg.appendSlice(ga, res);
            ga.free(res);
            i += 1;
        }
        try msg.append(ga, '\n');
    }
    _ = msg.pop();

    var write_buf: [1024]u8 = undefined;
    try client.writer_mutex.lock(io);
    defer client.writer_mutex.unlock(io);
    var writer = client.conn.writer(io, &write_buf);
    const w = &writer.interface;
    client.errWriteAll(w, msg.items) orelse return;
    client.errFlush(w) orelse return;
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
const State = types.ServState;
const Client = State.Client;
const Token = types.Token;
const Packet = types.Packet;
const PacketType = types.PacketType;
const utils = @import("utils");
const bufPrint = std.fmt.bufPrint;
const allocPrint = std.fmt.allocPrint;
const getClientById = utils.getClientById;
const getClientByName = utils.getClientByName;
const Stringify = std.json.Stringify;
const valueAlloc = Stringify.valueAlloc;
