const std = @import("std");
const eql = std.mem.eql;
const info = std.log.info;
const net = std.net;
const types = @import("types");
const Client = types.Client;
const State = types.State;
const utils = @import("utils");
const errWrite = utils.errWrite;
const errFlush = utils.errFlush;
const getClientById = utils.getClientById;
const getClientByName = utils.getClientByName;

fn linkClients(client1: *Client, client2: *Client, state: *State) void {
    if (client1 == client2) return;
    const id1 = client1.id;
    const id2 = client2.id;
    const conn = &state.links;

    const f = conn.getPtr(id1) orelse {
        info("Invalid id {d}", .{id1});
        return;
    };
    const s = conn.getPtr(id2) orelse {
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
        errWrite(w, "Not connected to {s}.\n", .{to.name orelse "NA"}, from) orelse return;
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
        errWrite(w, "Not connected to {s}.\n", .{from.name orelse "NA"}, to) orelse return;
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
    errWrite(w, "({s}, {d}): {s}", .{ from.name orelse "NA", from.id, to_send }, to) orelse return;
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
        errWrite(w, "({s}, {d}): {s}", .{ from.name orelse "NA", from.id, to_send }, c) orelse return;
        errFlush(w, c) orelse return;
    }
}

fn displayClients(client: *Client, state: *State) void {
    var buf: [1024]u8 = undefined;
    client.writer_mutex.lock();
    defer client.writer_mutex.unlock();
    var writer = client.conn.stream.writer(&buf);
    const w = &writer.interface;

    errWrite(w, "id\tNAME\tLINK\n", .{}, client) orelse return;
    for (state.clients.items) |c| {
        errWrite(w, "{d}\t{s}", .{ c.id, c.name orelse "NA" }, client) orelse return;
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
    defer cleanupClient(client, state);
    const conn = client.conn;
    info("Accepted connection from {f}, {d}", .{ conn.address, client.id });

    var read_buf: [1024]u8 = undefined;
    var reader = conn.stream.reader(&read_buf);

    while (true) {
        info("Waiting for data from {d}...", .{client.id});
        const msg = reader.interface().takeDelimiterInclusive('\n') catch |err| {
            switch (err) {
                error.EndOfStream => {
                    info("Connection closed by client {d}", .{client.id});
                    return;
                },
                error.ReadFailed => {
                    info("Failed to read message from {d}", .{client.id});
                    info("Closing...", .{});
                    return;
                },
                else => return,
            }
        };
        info("{d} says {s}", .{ client.id, msg });
        parseHeaderAndAct(client, msg, state);
    }
}

fn cleanupClient(client: *Client, state: *State) void {
    const id = client.id;
    state.mutex.lock();
    defer state.mutex.unlock();
    if (client.name != null) state.ga.free(client.name.?);
    const clients = &state.clients;
    for (clients.items, 0..) |c, i| {
        if (c == client) {
            _ = clients.swapRemove(@intCast(i));
            break;
        }
    } else {
        info("Client not found in the clients list.\n", .{});
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
    state.ga.destroy(client);
}

fn parseHeaderAndAct(client: *Client, msg: []u8, state: *State) void {
    state.mutex.lock();
    defer state.mutex.unlock();

    var itr = std.mem.splitAny(u8, msg, " \n");
    var write_buf: [1024]u8 = undefined;
    const header = itr.next() orelse return;
    if (eql(u8, header, "ECHO")) {
        const to_echo = msg[header.len..];
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
        errWrite(w, "name: {s}, id: {d}\n", .{ client.name orelse "NA", client.id }, client) orelse return;
        errFlush(w, client) orelse return;
    } else if (eql(u8, header, "NAME")) {
        const name = itr.next() orelse {
            client.writer_mutex.lock();
            defer client.writer_mutex.unlock();
            var writer = client.conn.stream.writer(&write_buf);
            const w = &writer.interface;
            errWrite(w, "Missing name", .{}, client) orelse return;
            errFlush(w, client) orelse return;
            return;
        };
        if (client.name != null) state.ga.free(client.name.?);
        client.name = state.ga.dupe(u8, name) catch |err| {
            info("Failed to set name for {d}: {any}", .{ client.id, err });
            return;
        };
        info("Named {d} -> {s}\n", .{ client.id, name });
    } else if (eql(u8, header, "LINK")) {
        const buf = itr.next() orelse {
            client.writer_mutex.lock();
            defer client.writer_mutex.unlock();
            var writer = client.conn.stream.writer(&write_buf);
            const w = &writer.interface;
            errWrite(w, "Missing id to connect to", .{}, client) orelse return;
            errFlush(w, client) orelse return;
            return;
        };
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
        return;
    } else if (eql(u8, header, "SENDTO")) {
        var writer = client.conn.stream.writer(&write_buf);
        const w = &writer.interface;
        const buf = itr.next() orelse {
            errWrite(w, "No id/name specified\n", .{}, client) orelse return;
            errFlush(w, client) orelse return;
            return;
        };
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
        errWrite(w, "Failed to connect to {s}. Invalid id or name\n", .{buf}, client) orelse return;
        errFlush(w, client) orelse return;
        return;
    } else if (eql(u8, header, "ALL")) {
        sendAll(client, itr.rest());
    } else if (eql(u8, header, "GETINFO")) {
        displayClients(client, state);
    }
}
