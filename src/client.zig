const std = @import("std");
const info = std.log.info;
const net = std.net;
const types = @import("types");
const Client = types.Client;
const State = types.State;

fn connectClients(id1: usize, id2: usize, state: *State) void {
    if (id1 == id2) return;
    state.mutex.lock();
    defer state.mutex.unlock();

    const conn = &state.connections;

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
    info("Connected {d} and {d}", .{ id1, id2 });
}

pub fn displayClients(client: *Client, state: *State) void {
    state.mutex.lock();
    defer state.mutex.unlock();

    var buf: [1024]u8 = undefined;
    client.writer_mutex.lock();
    defer client.writer_mutex.unlock();
    var writer = client.conn.stream.writer(&buf);

    writer.interface.writeAll("ID\tNAME\tCONN\n") catch |err| {
        info("Write failed to {d}: {any}", .{ client.id, err });
        return;
    };
    for (state.clients.items) |c| {
        writer.interface.print("{d}\t{s}\t", .{ c.id, c.name orelse "NA" }) catch |err| {
            info("Write failed to {d}: {any}", .{ client.id, err });
            return;
        };

        const conns = state.connections.getPtr(c.id).?;
        var itr = conns.iterator();
        while (itr.next()) |node| {
            writer.interface.print("{d},", .{node.key}) catch |err| {
                info("Write failed to {d}: {any}", .{ client.id, err });
                return;
            };
        }
        writer.interface.writeAll("\x08\n") catch |err| {
            info("Write failed to {d}: {any}", .{ client.id, err });
            return;
        };

        writer.interface.flush() catch |err| {
            info("Flush failed to {d}: {any}", .{ client.id, err });
            return;
        };
    }
}

pub fn handleClient(client: *Client, state: *State) void {
    defer cleanupClient(client, state);
    const conn = client.conn;
    info("Accepted connection from {f}, {d}", .{ conn.address, client.id });

    var read_buf: [1024]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
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
        const instruction = parseHeaderAndAct(client, msg, state);
        if (instruction) continue;

        client.writer_mutex.lock();
        defer client.writer_mutex.unlock();
        var writer = conn.stream.writer(&write_buf);
        writer.interface.writeAll(msg) catch |err| {
            info("Write failed to {d}: {any}", .{ client.id, err });
            return;
        };
        writer.interface.flush() catch |err| {
            info("Flush failed to {d}: {any}", .{ client.id, err });
            return;
        };
    }
}

fn cleanupClient(client: *Client, state: *State) void {
    var idx: i32 = -1;
    const id = client.id;
    state.mutex.lock();
    defer state.mutex.unlock();
    if (client.name != null) state.ga.free(client.name.?);
    const clients = &state.clients;
    for (clients.items, 0..) |c, i| {
        if (c == client) {
            idx = @intCast(i);
            break;
        }
    }
    if (idx != -1) {
        _ = clients.swapRemove(@intCast(idx));
    } else {
        info("Client not found in the clients list.\n", .{});
    }
    const connections = &state.connections;
    for (clients.items) |c| {
        if (c.id != client.id) {
            connections.getPtr(c.id).?.remove(id);
        }
    }
    state.ga.destroy(client);
}

fn parseHeaderAndAct(client: *Client, msg: []u8, state: *State) bool {
    var itr = std.mem.splitAny(u8, msg, " \n");
    const header = itr.next() orelse return false;
    if (std.mem.eql(u8, header, "NAME")) {
        const name = itr.next() orelse {
            client.writer_mutex.lock();
            defer client.writer_mutex.unlock();
            var write_buf: [1024]u8 = undefined;
            var writer = client.conn.stream.writer(&write_buf);
            writer.interface.writeAll("Missing name") catch |err| {
                info("Write failed to {d}: {any}", .{ client.id, err });
            };
            writer.interface.flush() catch |err| {
                info("Flush failed to {d}: {any}", .{ client.id, err });
            };
            return false;
        };
        if (client.name != null) state.ga.free(client.name.?);
        client.name = state.ga.dupe(u8, name) catch |err| {
            info("Failed to set name for {d}: {any}", .{ client.id, err });
            return false;
        };
        info("{d} -> {s}\n", .{ client.id, name });
        return true;
    } else if (std.mem.eql(u8, header, "GETINFO")) {
        displayClients(client, state);
        return true;
    } else if (std.mem.eql(u8, header, "CONNECT")) {
        const id_buf = itr.next() orelse {
            client.writer_mutex.lock();
            defer client.writer_mutex.unlock();
            var write_buf: [1024]u8 = undefined;
            var writer = client.conn.stream.writer(&write_buf);
            writer.interface.writeAll("Missing id to connect to") catch |err| {
                info("Write failed to {d}: {any}", .{ client.id, err });
            };
            writer.interface.flush() catch |err| {
                info("Flush failed to {d}: {any}", .{ client.id, err });
            };
            return false;
        };
        const id = std.fmt.parseInt(u8, id_buf, 10) catch |perr| {
            info("Parsing error when trying to connect {d}: {any}", .{ client.id, perr });
            client.writer_mutex.lock();
            defer client.writer_mutex.unlock();
            var write_buf: [1024]u8 = undefined;
            var writer = client.conn.stream.writer(&write_buf);
            writer.interface.print("Invalid ID {s}", .{id_buf}) catch |err| {
                info("Write failed to {d}: {any}", .{ client.id, err });
            };
            writer.interface.flush() catch |err| {
                info("Flush failed to {d}: {any}", .{ client.id, err });
            };
            return false;
        };
        connectClients(client.id, id, state);
        return true;
    }
    return false;
}
