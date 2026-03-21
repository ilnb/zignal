const std = @import("std");
const eql = std.mem.eql;
const info = std.log.info;
const net = std.net;
const types = @import("types");
const Client = types.Client;
const State = types.State;
const Token = types.Token;
const utils = @import("utils");
const bufPrint = std.fmt.bufPrint;
const errWrite = utils.errWrite;
const errFlush = utils.errFlush;
const getClientById = utils.getClientById;
const getClientByName = utils.getClientByName;

fn linkClients(client1: *Client, client2: *Client, state: *State) void {
    if (client1 == client2) return;
    const id1 = client1.id;
    const id2 = client2.id;
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

    client1.active_mutex.lock();
    defer client1.active_mutex.unlock();
    client1.active.append(state.ga.*, client2) catch |err| {
        info("Error appending active {any}", .{err});
        return;
    };

    client2.active_mutex.lock();
    defer client2.active_mutex.unlock();
    client2.active.append(state.ga.*, client1) catch |err| {
        info("Error appending active {any}", .{err});
        return;
    };

    info("Connected {d} and {d}", .{ id1, id2 });
}

fn unlinkClients(client1: *Client, client2: *Client, state: *State) void {
    if (client1 == client2) return;
    const id1 = client1.id;
    const id2 = client2.id;
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

    client1.active_mutex.lock();
    defer client1.active_mutex.unlock();
    for (client1.active.items, 0..) |c, i| {
        if (c == client2) {
            _ = client1.active.swapRemove(i);
            break;
        }
    }

    client2.active_mutex.lock();
    defer client2.active_mutex.unlock();
    for (client2.active.items, 0..) |c, i| {
        if (c == client1) {
            _ = client2.active.swapRemove(i);
            break;
        }
    }

    info("Disconnected {d} and {d}", .{ id1, id2 });
}

fn sendMsg(from: *Client, to: *Client, to_send: []const u8) void {
    if (from == to) return;

    var buf: [1024]u8 = undefined;
    from.active_mutex.lock();
    defer from.active_mutex.unlock();
    _ = for (from.active.items) |c| {
        if (c == to) break c;
    } else {
        from.writer_mutex.lock();
        defer from.writer_mutex.unlock();
        var writer = from.conn.stream.writer(&buf);
        const w = &writer.interface;
        errWrite(w, "Not connected to {s}.\n", .{to.name}, from) orelse return;
        errFlush(w, from) orelse return;
        return;
    };

    to.active_mutex.lock();
    defer to.active_mutex.unlock();
    _ = for (to.active.items) |c| {
        if (c == from) break c;
    } else {
        to.writer_mutex.lock();
        defer to.writer_mutex.unlock();
        var writer = to.conn.stream.writer(&buf);
        const w = &writer.interface;
        errWrite(w, "Not connected to {s}.\n", .{from.name}, to) orelse return;
        errFlush(w, to) orelse return;
        return;
    };

    if (to_send.len == 0) {
        from.writer_mutex.lock();
        defer from.writer_mutex.unlock();
        var writer = from.conn.stream.writer(&buf);
        const w = &writer.interface;
        errWrite(w, "Empty message.\n", .{}, from) orelse return;
        errFlush(w, from) orelse return;
        return;
    }

    to.writer_mutex.lock();
    defer to.writer_mutex.unlock();
    var writer = to.conn.stream.writer(&buf);
    const w = &writer.interface;
    errWrite(w, "({s}, {d}): {s}", .{ from.name, from.id, to_send }, to) orelse return;
    errFlush(w, to) orelse return;
}

fn sendAll(from: *Client, to_send: []const u8) void {
    if (to_send.len == 0) return;
    var buf: [1024]u8 = undefined;
    from.active_mutex.lock();
    defer from.active_mutex.unlock();
    for (from.active.items) |c| {
        c.writer_mutex.lock();
        defer c.writer_mutex.unlock();
        var writer = c.conn.stream.writer(&buf);
        const w = &writer.interface;
        errWrite(w, "({s}, {d}): {s}", .{ from.name, from.id, to_send }, c) orelse return;
        errFlush(w, c) orelse return;
    }
}

fn displayClient(client: *Client, to_fetch: *Client, state: *State) void {
    var write_buf: [1024]u8 = undefined;
    client.writer_mutex.lock();
    defer client.writer_mutex.unlock();
    var writer = client.conn.stream.writer(&write_buf);
    const w = &writer.interface;
    errWrite(w, "ID\tNAME\tLINK\n", .{}, client) orelse return;
    errWrite(w, "{d}\t{s}", .{ to_fetch.id, to_fetch.name }, client) orelse return;
    if (to_fetch.id == client.id) {
        errWrite(w, "*", .{}, client) orelse return;
    }
    errWrite(w, "\t", .{}, client) orelse return;

    const conns = state.links.getPtr(to_fetch.id).?;
    var itr = conns.iterator();
    var i: usize = 1;
    while (itr.next()) |node| {
        errWrite(w, "{d}{s}", .{ node.key, if (i != conns.count) ", " else "" }, client) orelse return;
        i += 1;
    }
    errWrite(w, "\n", .{}, client) orelse return;
    errFlush(w, client) orelse return;
}

fn displayAll(client: *Client, state: *State) void {
    var buf: [1024]u8 = undefined;
    client.writer_mutex.lock();
    defer client.writer_mutex.unlock();
    var writer = client.conn.stream.writer(&buf);
    const w = &writer.interface;

    errWrite(w, "ID\tNAME\tLINK\n", .{}, client) orelse return;
    for (state.clients.items) |c| {
        errWrite(w, "{d}\t{s}", .{ c.id, c.name }, client) orelse return;
        if (c.id == client.id) {
            errWrite(w, "*", .{}, client) orelse return;
        }
        errWrite(w, "\t", .{}, client) orelse return;

        const conns = state.links.getPtr(c.id).?;
        var itr = conns.iterator();
        var i: usize = 1;
        while (itr.next()) |node| {
            errWrite(w, "{d}{s}", .{ node.key, if (i != conns.count) ", " else "" }, client) orelse return;
            i += 1;
        }
        errWrite(w, "\n", .{}, client) orelse return;
        errFlush(w, client) orelse return;
    }
}

pub fn handleClient(client: *Client, state: *State) void {
    // defer cleanupClient(client, state);
    defer client.online = false;
    const conn = client.conn;
    info("Accepted connection from {f}, {d}", .{ conn.address, client.id });

    var read_buf: [1024]u8 = undefined;
    var reader_file = conn.stream.reader(&read_buf).file_reader;
    const reader = &reader_file.interface;

    while (true) {
        info("Waiting for data from {d}...", .{client.id});
        const msg = reader.takeDelimiter('\n') catch |err| {
            switch (err) {
                error.ReadFailed => {
                    info("Failed to read message from {d}", .{client.id});
                    info("Closing...", .{});
                    return;
                },
                else => return,
            }
        } orelse {
            info("Connection closed by client {d}", .{client.id});
            return;
        };
        info("{d} says {s}", .{ client.id, msg });
        parseHeaderAndAct(client, msg, state);
    }
}

fn cleanupClient(client: *Client, state: *State) void {
    const id = client.id;
    state.mutex.lock();
    defer state.mutex.unlock();
    const clients = &state.clients;
    for (clients.items, 0..) |c, i| {
        if (c == client) {
            _ = clients.swapRemove(@intCast(i));
            break;
        }
    } else {
        info("Client not found in the clients list", .{});
    }

    const links = &state.links;
    for (clients.items) |c| {
        if (c.id != client.id) links.getPtr(c.id).?.remove(id);
        c.active_mutex.lock();
        defer c.active_mutex.unlock();
        for (c.active.items, 0..) |c_, i| {
            if (c_.id == id) {
                _ = c.active.swapRemove(i);
                break;
            }
        }
    }
    client.conn.stream.close();
    state.ga.destroy(client);
}

fn parseHeaderAndAct(client: *Client, msg: []u8, state: *State) void {
    state.mutex.lock();
    defer state.mutex.unlock();

    var itr = std.mem.splitAny(u8, msg, " \n");
    var write_buf: [1024]u8 = undefined;
    const header = itr.next() orelse return;
    if (eql(u8, header, "ECHO")) {
        const to_echo = itr.rest();
        client.writer_mutex.lock();
        defer client.writer_mutex.unlock();
        var writer = client.conn.stream.writer(&write_buf);
        const w = &writer.interface;
        errWrite(w, "{s}\n", .{to_echo}, client) orelse return;
        errFlush(w, client) orelse return;
    } else if (eql(u8, header, "WHOAMI")) {
        client.writer_mutex.lock();
        defer client.writer_mutex.unlock();
        var writer = client.conn.stream.writer(&write_buf);
        const w = &writer.interface;
        errWrite(w, "name: {s}, id: {d}\n", .{ client.name, client.id }, client) orelse return;
        errFlush(w, client) orelse return;
    } else if (eql(u8, header, "NAME")) {
        const nbuf = while (itr.next()) |s| {
            if (s.len > 0) break s;
        } else null;
        if (nbuf == null) {
            client.writer_mutex.lock();
            defer client.writer_mutex.unlock();
            var writer = client.conn.stream.writer(&write_buf);
            const w = &writer.interface;
            errWrite(w, "No id or name specified\n", .{}, client) orelse return;
            errFlush(w, client) orelse return;
            return;
        }
        const name = nbuf.?;
        const token: *Token = for (state.tokens.items) |*t| {
            if (t.rid == client.id) break t;
        } else {
            info("Corrupted tokens list. Client with {d} not found.\n", .{client.id});
            return;
        };
        updateTokenFile(name, token, state) catch |err| {
            info("Failed to update tokens file with error: {any}. Not renaming client {d}", .{ err, client.id });
            return;
        };
        state.ga.free(token.name);
        token.name = state.ga.dupe(u8, name) catch |err| {
            info("Failed to set name for {d}: {any}", .{ client.id, err });
            return;
        };
        client.name = token.name;
        info("Named {d} -> {s}\n", .{ client.id, name });
    } else if (eql(u8, header, "LINK")) {
        const nbuf = while (itr.next()) |s| {
            if (s.len > 0) break s;
        } else null;
        if (nbuf == null) {
            client.writer_mutex.lock();
            defer client.writer_mutex.unlock();
            var writer = client.conn.stream.writer(&write_buf);
            const w = &writer.interface;
            errWrite(w, "No id or name specified\n", .{}, client) orelse return;
            errFlush(w, client) orelse return;
            return;
        }
        const buf = nbuf.?;
        var c2 = getClientById(buf, state);
        if (c2 != null) {
            linkClients(client, c2.?, state);
            return;
        }
        c2 = getClientByName(buf, state);
        if (c2 != null) {
            linkClients(client, c2.?, state);
            return;
        }
        client.writer_mutex.lock();
        defer client.writer_mutex.unlock();
        var writer = client.conn.stream.writer(&write_buf);
        const w = &writer.interface;
        errWrite(w, "Failed to connect to {s}. Invalid id or name\n", .{buf}, client) orelse return;
        errFlush(w, client) orelse return;
    } else if (eql(u8, header, "UNLINK")) {
        const nbuf = while (itr.next()) |s| {
            if (s.len > 0) break s;
        } else null;
        if (nbuf == null) {
            client.writer_mutex.lock();
            defer client.writer_mutex.unlock();
            var writer = client.conn.stream.writer(&write_buf);
            const w = &writer.interface;
            errWrite(w, "No id or name specified\n", .{}, client) orelse return;
            errFlush(w, client) orelse return;
            return;
        }
        const buf = nbuf.?;
        var c2 = getClientById(buf, state);
        if (c2 != null) {
            unlinkClients(client, c2.?, state);
            return;
        }
        c2 = getClientByName(buf, state);
        if (c2 != null) {
            unlinkClients(client, c2.?, state);
            return;
        }
        client.writer_mutex.lock();
        defer client.writer_mutex.unlock();
        var writer = client.conn.stream.writer(&write_buf);
        const w = &writer.interface;
        errWrite(w, "Failed to unlink from {s}. Invalid id or name\n", .{buf}, client) orelse return;
        errFlush(w, client) orelse return;
    } else if (eql(u8, header, "SENDTO")) {
        const nbuf = while (itr.next()) |s| {
            if (s.len > 0) break s;
        } else null;
        if (nbuf == null) {
            client.writer_mutex.lock();
            defer client.writer_mutex.unlock();
            var writer = client.conn.stream.writer(&write_buf);
            const w = &writer.interface;
            errWrite(w, "No id or name specified\n", .{}, client) orelse return;
            errFlush(w, client) orelse return;
            return;
        }
        const buf = nbuf.?;
        const to_send = itr.rest();
        var c2 = getClientById(buf, state);
        if (c2 != null) {
            sendMsg(client, c2.?, to_send);
            return;
        }
        c2 = getClientByName(buf, state);
        if (c2 != null) {
            sendMsg(client, c2.?, to_send);
            return;
        }
        client.writer_mutex.lock();
        defer client.writer_mutex.unlock();
        var writer = client.conn.stream.writer(&write_buf);
        const w = &writer.interface;
        errWrite(w, "Failed to connect to {s}. Invalid id or name\n", .{buf}, client) orelse return;
        errFlush(w, client) orelse return;
    } else if (eql(u8, header, "ALL")) {
        sendAll(client, itr.rest());
    } else if (eql(u8, header, "GETINFO")) {
        const buf = while (itr.next()) |s| {
            if (s.len > 0) break s;
        } else null;
        if (buf != null) {
            var to_fetch = getClientById(buf.?, state);
            if (to_fetch != null) {
                displayClient(client, to_fetch.?, state);
                return;
            }
            to_fetch = getClientByName(buf.?, state);
            if (to_fetch != null) {
                displayClient(client, to_fetch.?, state);
                return;
            }
            client.writer_mutex.lock();
            defer client.writer_mutex.unlock();
            var writer = client.conn.stream.writer(&write_buf);
            const w = &writer.interface;
            errWrite(w, "Failed to getinfo of {s}. Invalid id or name\n", .{buf.?}, client) orelse return;
            errFlush(w, client) orelse return;
        } else {
            displayAll(client, state);
        }
    }
}

pub const HandshakeResult = union(enum) {
    new: Token,
    existing: usize,
};

pub fn handshakeWithClient(conn: net.Server.Connection, state: *State) !HandshakeResult {
    var buf: [128]u8 = undefined;
    var reader_file = conn.stream.reader(buf[0..64]).file_reader;
    const reader = &reader_file.interface;
    var writer_file = conn.stream.writer(buf[64..]).file_writer;
    const writer = &writer_file.interface;
    const msg = try reader.takeDelimiter('\n') orelse return error.EmptyMessage;
    info("Recieved handshake message {s} from client {f}", .{ msg, conn.address });

    var itr = std.mem.splitAny(u8, msg, " \n");
    const new_or_old = itr.next() orelse return error.BadHandshake;
    const token_id = itr.next() orelse return error.BadHandshake;

    var idx: i32 = -1;
    for (state.tokens.items, 0..) |t, i| {
        if (std.mem.eql(u8, t.id, token_id)) {
            idx = @intCast(i);
            break;
        }
    }
    if (idx != -1) {
        if (std.mem.eql(u8, new_or_old, "NEW")) return error.KnownClient;
        try writer.writeAll("OK\n");
        try writer.flush();
        return .{ .existing = @intCast(idx) };
    } else {
        if (std.mem.eql(u8, new_or_old, "OLD")) return error.UnknownClient;
        try writer.writeAll("OK\n");
        try writer.flush();
        return .{ .new = Token{ .id = try state.ga.dupe(u8, token_id), .name = try state.ga.dupe(u8, "NA"), .rid = 0 } };
    }
}

fn updateTokenFile(name: []const u8, token: *Token, state: *State) !void {
    const tmp_file = try state.profile_dir.createFile("token.tmp", .{});
    var buf: [1024]u8 = undefined;
    var writer_f = tmp_file.writer(&buf);
    const writer = &writer_f.interface;
    for (state.tokens.items) |*t| {
        try writer.print("{s} ", .{t.id});
        if (token == t) {
            try writer.print("{s}\n", .{name});
        } else {
            @branchHint(.likely);
            try writer.print("{s}\n", .{t.name});
        }
        try writer.flush();
    }
    try state.profile_dir.rename("token.tmp", "token");
}
