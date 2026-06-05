const std = @import("std");
const eql = std.mem.eql;
const info = std.log.info;
const net = std.Io.net;
const types = @import("types");
const State = types.ServState;
const Client = State.Client;
const Token = types.Token;
const utils = @import("utils");
const bufPrint = std.fmt.bufPrint;
const getClientById = utils.getClientById;
const getClientByName = utils.getClientByName;

pub fn handleClient(client: *Client, state: *State) !void {
    // defer cleanupClient(client, state);
    defer client.online = false;
    const conn = client.conn;
    info("Accepted connection from {f}, {d}", .{ conn.socket.address, client.rid });

    var read_buf: [1024]u8 = undefined;
    var reader_file = conn.reader(state.io, &read_buf);
    const reader = &reader_file.interface;

    while (true) {
        info("Waiting for data from {d}...", .{client.rid});
        const msg = reader.takeDelimiter('\n') catch |err| {
            switch (err) {
                error.ReadFailed => {
                    info("Failed to read message from {d}", .{client.rid});
                    info("Closing...", .{});
                },
                else => {
                    info("Message buffer overflowed", .{});
                },
            }
            break;
        } orelse {
            info("Connection closed by client {d}", .{client.rid});
            break;
        };
        const trimmed = std.mem.trim(u8, msg, " ");
        if (trimmed.len == 0) continue;
        info("{d} says {s}", .{ client.rid, trimmed });
        try parseHeaderAndAct(client, trimmed, state);
    }
}

fn parseHeaderAndAct(client: *Client, msg: []const u8, state: *State) !void {
    const io = state.io;
    try state.mutex.lock(io);
    defer state.mutex.unlock(io);

    var itr = std.mem.tokenizeScalar(u8, msg, ' ');
    var write_buf: [1024]u8 = undefined;
    const header = itr.next() orelse return;
    if (eql(u8, header, "ECHO")) {
        const to_echo = itr.rest();
        try client.writer_mutex.lock(io);
        defer client.writer_mutex.unlock(io);
        var writer = client.conn.writer(io, &write_buf);
        const w = &writer.interface;
        client.errWrite(w, "{s}\n", .{to_echo}) orelse return;
        client.errFlush(w) orelse return;
    } else if (eql(u8, header, "WHOAMI")) {
        try client.writer_mutex.lock(io);
        defer client.writer_mutex.unlock(io);
        var writer = client.conn.writer(io, &write_buf);
        const w = &writer.interface;
        client.errWrite(w, "name: {s}, id: {d}\n", .{ client.name, client.rid }) orelse return;
        client.errFlush(w) orelse return;
    } else if (eql(u8, header, "NAME")) {
        const name = itr.next() orelse {
            try client.writer_mutex.lock(io);
            defer client.writer_mutex.unlock(io);
            var writer = client.conn.writer(io, &write_buf);
            const w = &writer.interface;
            client.errWriteAll(w, "No id or name specified\n") orelse return;
            client.errFlush(w) orelse return;
            return;
        };
        var num_count: usize = 0;
        for (name) |c| {
            if (c >= '0' and c <= '9') num_count += 1;
        }
        if (num_count == name.len) {
            try client.writer_mutex.lock(io);
            defer client.writer_mutex.unlock(io);
            var writer = client.conn.writer(io, &write_buf);
            const w = &writer.interface;
            client.errWriteAll(w, "All numeric name is not allowed\n") orelse return;
            client.errFlush(w) orelse return;
            return;
        }
        const token: *Token = for (state.tokens.items) |*t| {
            if (t.rid) |rid| if (rid == client.rid) break t;
        } else {
            info("Corrupted tokens list. Client with {d} not found.", .{client.rid});
            return;
        };
        state.ga.free(token.name);
        token.name = state.ga.dupe(u8, name) catch |err| {
            info("Failed to set name for {d}: {any}", .{ client.rid, err });
            return;
        };
        client.name = token.name;
        try client.writer_mutex.lock(io);
        defer client.writer_mutex.unlock(io);
        var writer = client.conn.writer(io, &write_buf);
        const w = &writer.interface;
        client.errWriteAll(w, "\n") orelse return;
        client.errFlush(w) orelse return;
        info("Named {d} -> {s}", .{ client.rid, name });
    } else if (eql(u8, header, "LINK")) {
        try client.writer_mutex.lock(io);
        defer client.writer_mutex.unlock(io);
        var writer = client.conn.writer(io, &write_buf);
        const w = &writer.interface;
        const buf = itr.next() orelse {
            client.errWriteAll(w, "No id or name specified\n") orelse return;
            client.errFlush(w) orelse return;
            return;
        };
        const c2 = getClientById(state, buf) orelse getClientByName(state, buf) orelse {
            client.errWrite(w, "Failed to connect to {s}. Invalid id or name\n", .{buf}) orelse return;
            client.errFlush(w) orelse return;
            return;
        };
        try linkClients(client, c2, state);
        client.errWriteAll(w, "\n") orelse return;
        client.errFlush(w) orelse return;
    } else if (eql(u8, header, "UNLINK")) {
        try client.writer_mutex.lock(io);
        defer client.writer_mutex.unlock(io);
        var writer = client.conn.writer(io, &write_buf);
        const w = &writer.interface;
        const buf = itr.next() orelse {
            client.errWriteAll(w, "No id or name specified\n") orelse return;
            client.errFlush(w) orelse return;
            return;
        };
        const c2 = getClientById(state, buf) orelse getClientByName(state, buf) orelse {
            client.errWrite(w, "Failed to unlink from {s}. Invalid id or name\n", .{buf}) orelse return;
            client.errFlush(w) orelse return;
            return;
        };
        try unlinkClients(client, c2, state);
        client.errWriteAll(w, "\n") orelse return;
        client.errFlush(w) orelse return;
    } else if (eql(u8, header, "SENDTO")) {
        var writer = client.conn.writer(io, &write_buf);
        const w = &writer.interface;
        const buf = itr.next() orelse {
            try client.writer_mutex.lock(io);
            defer client.writer_mutex.unlock(io);
            client.errWriteAll(w, "No id or name specified\n") orelse return;
            client.errFlush(w) orelse return;
            return;
        };
        const to_send = std.mem.trim(u8, itr.rest(), " \n");
        const c2 = getClientById(state, buf) orelse getClientByName(state, buf) orelse {
            try client.writer_mutex.lock(io);
            defer client.writer_mutex.unlock(io);
            client.errWrite(w, "Failed to send message to {s}. Invalid id or name\n", .{buf}) orelse return;
            client.errFlush(w) orelse return;
            return;
        };
        try sendMsg(io, client, c2, to_send);
        try client.writer_mutex.lock(io);
        defer client.writer_mutex.unlock(io);
        client.errWriteAll(w, "\n") orelse return;
        client.errFlush(w) orelse return;
    } else if (eql(u8, header, "ALL")) {
        try sendAll(io, client, std.mem.trim(u8, itr.rest(), " \n"));
        var writer = client.conn.writer(io, &write_buf);
        const w = &writer.interface;
        try client.writer_mutex.lock(io);
        defer client.writer_mutex.unlock(io);
        client.errWriteAll(w, "\n") orelse return;
        client.errFlush(w) orelse return;
    } else if (eql(u8, header, "GETINFO")) {
        const buf = itr.next() orelse {
            try displayAll(client, state);
            return;
        };
        const to_fetch = getClientById(state, buf) orelse getClientByName(state, buf) orelse {
            try client.writer_mutex.lock(io);
            defer client.writer_mutex.unlock(io);
            var writer = client.conn.writer(io, &write_buf);
            const w = &writer.interface;
            client.errWrite(w, "Failed to getinfo of {s}. Invalid id or name\n", .{buf}) orelse return;
            client.errFlush(w) orelse return;
            return;
        };
        try displayClient(client, to_fetch, state);
    } else {
        var writer = client.conn.writer(io, &write_buf);
        const w = &writer.interface;
        try client.writer_mutex.lock(io);
        defer client.writer_mutex.unlock(io);
        client.errWrite(w, "Invalid cmd {s}\n", .{header}) orelse return;
        client.errFlush(w) orelse return;
    }
}

fn linkClients(client1: *Client, client2: *Client, state: *State) !void {
    if (client1 == client2) {
        var buf: [20]u8 = undefined;
        var writer = client1.conn.writer(state.io, &buf);
        const w = &writer.interface;
        try client1.writer_mutex.lock(state.io);
        defer client1.writer_mutex.unlock(state.io);
        client1.errWriteAll(w, "Self link.\n") orelse return;
        client1.errFlush(w) orelse return;
        return;
    }
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
        bufPrint(&buf, "Client {d} is offline.\n", .{to.rid}) catch "Specified client is offline.\n"
    else if (from == to)
        "Self message.\n"
    else if (to_send.len == 0)
        "Empty message.\n"
    else
        null;

    if (err_msg != null) {
        try from.writer_mutex.lock(io);
        defer from.writer_mutex.unlock(io);
        var writer = from.conn.writer(io, &buf);
        const w = &writer.interface;
        from.errWriteAll(w, err_msg.?) orelse return;
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
        from.errWrite(w, "Not connected to {s}.\n", .{to.name}) orelse return;
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
        to.errWrite(w, "Not connected to {s}.\n", .{from.name}) orelse return;
        to.errFlush(w) orelse return;
        return;
    };

    try to.writer_mutex.lock(io);
    defer to.writer_mutex.unlock(io);
    var writer = to.conn.writer(io, &buf);
    const w = &writer.interface;
    to.errWrite(w, "({s}, {d}): {s}\n", .{ from.name, from.rid, to_send }) orelse return;
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
        c.errWrite(w, "({s}, {d}): {s}\n", .{ from.name, from.rid, to_send }) orelse return;
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

    var write_buf: [1024]u8 = undefined;
    try client.writer_mutex.lock(io);
    defer client.writer_mutex.unlock(io);
    var writer = client.conn.writer(io, &write_buf);
    const w = &writer.interface;
    client.errWrite(w, "{s: <[2]}{s: <[3]}LINK\n", .{ "ID", "NAME", id_w, name_w }) orelse return;

    var name_buf: [256]u8 = undefined;
    const name = if (to_fetch.rid == client.rid)
        std.fmt.bufPrint(&name_buf, "{s}*", .{to_fetch.name}) catch to_fetch.name
    else
        to_fetch.name;
    client.errWrite(w, "{d: <[2]}{s: <[3]}", .{ to_fetch.rid, name, id_w, name_w }) orelse return;

    const conns = state.links.getPtr(to_fetch.rid).?;
    var itr = conns.iterator();
    var i: usize = 1;
    while (itr.next()) |node| {
        client.errWrite(w, "{d}{s}", .{ node.key, if (i != conns.count) ", " else "" }) orelse return;
        i += 1;
    }
    client.errWriteAll(w, "\n") orelse return;
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

    var buf: [1024]u8 = undefined;
    try client.writer_mutex.lock(io);
    defer client.writer_mutex.unlock(io);
    var writer = client.conn.writer(io, &buf);
    const w = &writer.interface;

    client.errWrite(w, "{s: <[2]}{s: <[3]}LINK\n", .{ "ID", "NAME", id_w, name_w }) orelse return;
    for (state.clients.items) |c| {
        var name_buf: [256]u8 = undefined;
        const name = if (c.rid == client.rid)
            std.fmt.bufPrint(&name_buf, "{s}*", .{c.name}) catch c.name
        else
            c.name;
        client.errWrite(w, "{d: <[2]}{s: <[3]}", .{ c.rid, name, id_w, name_w }) orelse return;

        const conns = state.links.getPtr(c.rid).?;
        var itr = conns.iterator();
        var i: usize = 1;
        while (itr.next()) |node| {
            client.errWrite(w, "{d}{s}", .{ node.key, if (i != conns.count) ", " else "" }) orelse return;
            i += 1;
        }
        client.errWriteAll(w, "\n") orelse return;
        client.errFlush(w) orelse return;
    }
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
        if (std.mem.eql(u8, t.id, token_id)) {
            break i;
        }
    } else null;

    if (idx != null) {
        if (std.mem.eql(u8, new_or_old, "NEW")) return error.KnownClient;
        try writer.writeAll("OK\n");
        try writer.flush();
        return .{ .existing = idx.? };
    } else {
        if (std.mem.eql(u8, new_or_old, "OLD")) return error.UnknownClient;
        try writer.writeAll("OK\n");
        try writer.flush();
        return .{ .new = Token{ .id = try state.ga.dupe(u8, token_id), .name = try state.ga.dupe(u8, "NA") } };
    }
}
