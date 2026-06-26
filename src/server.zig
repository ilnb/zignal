var running = std.atomic.Value(bool).init(true);

pub fn handleSig(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    if (!running.swap(false, .acq_rel)) return;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const aa = init.arena.allocator();
    const ga = init.gpa;
    const args = try init.minimal.args.toSlice(aa);

    var profile: []const u8 = "default";
    var port: u16 = 8000;
    const help_msg =
        \\Usage:
        \\ -h, --help            Display help
        \\ -p, --port <num>      Specify port, defaults to 8000
        \\ -P, --profile <name>  Specify profile, defaults to "default"
    ;

    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--profile") or
                std.mem.eql(u8, args[i], "-P"))
            {
                if (i + 1 == args.len) {
                    std.debug.print("Missing profile name. Try -h for more information.\n", .{});
                    return;
                }
                i += 1;
                profile = args[i];
            } else if (std.mem.eql(u8, args[i], "--port") or
                std.mem.eql(u8, args[i], "-p"))
            {
                if (i + 1 == args.len) {
                    std.debug.print("Missing port number. Try -h for more information.\n", .{});
                    return;
                }
                i += 1;
                port = std.fmt.parseInt(u16, args[i], 10) catch |err| {
                    std.debug.print("Error when parsing port number: {any}\n", .{err});
                    return;
                };
            } else if (std.mem.eql(u8, args[i], "--help") or
                std.mem.eql(u8, args[i], "-h"))
            {
                std.debug.print("{s}\n", .{help_msg});
                return;
            } else {
                std.debug.print("Invalid flag. {s}\n", .{help_msg});
                return;
            }
        }
    }

    var buf: [1024]u8 = undefined;

    const home = init.environ_map.get("HOME").?;
    var home_dir = try std.Io.Dir.openDirAbsolute(io, home, .{});
    defer home_dir.close(io);

    const profile_path = try bufPrint(&buf, ".config/zignal/server/{s}", .{profile});
    var profile_dir = try home_dir.createDirPathOpen(io, profile_path, .{});
    defer profile_dir.close(io);

    checkLock(init.io, &profile_dir) catch |err| {
        if (err != error.EndOfStream) {
            std.debug.print("Lock check failed with error: {any}\n", .{err});
        }
        return;
    };
    const lock_file = try profile_dir.createFile(io, "lock", .{});
    defer lock_file.close(io);
    defer profile_dir.deleteFile(io, "lock") catch {};

    const pid = std.os.linux.getpid();
    const pid_sl = try bufPrint(&buf, "{d}", .{pid});
    try lock_file.writeStreamingAll(io, pid_sl);

    const addr = net.IpAddress{ .ip4 = net.Ip4Address.unspecified(port) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    info("Server listening on port {d}", .{port});

    var state = State{
        .links = std.AutoHashMap(usize, Set(usize)).init(ga),
        .ga = ga,
        .aa = aa,
        .io = io,
        .profile_dir = profile_dir,
    };
    defer state.deinit();

    try populateTokens(&state);

    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSig },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.HUP, &sa, null);

    var fds = [_]posix.pollfd{
        .{ .fd = server.socket.handle, .events = posix.POLL.IN, .revents = 0 },
    };
    var id: usize = 0;
    while (running.load(.acquire)) {
        fds[0].revents = 0;
        if (posix.poll(&fds, 100) catch break == 0) continue;
        if (fds[0].revents & posix.POLL.IN == 0) continue;

        const conn = server.accept(io) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => {
                if (!running.load(.acquire)) break;
                return err;
            },
        };
        const no_timeout = posix.timeval{ .sec = 0, .usec = 0 };
        try posix.setsockopt(conn.socket.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(no_timeout));

        var result = server_mod.handshakeWithClient(conn, &state) catch |err| {
            defer conn.close(io);
            info("Handshake failed with client {f} with error {any}. Terminating connection", .{ conn.socket.address, err });
            const res = try std.fmt.allocPrint(ga, "ERR: {any}", .{err});
            defer ga.free(res);
            var c_writer = conn.writer(io, &buf);
            const w = &c_writer.interface;
            try Client.wSendData(state.aa, w, .{
                .err = res,
            }) orelse continue;
            continue;
        };

        var client: *Client = undefined;

        try state.mutex.lock(io);
        defer state.mutex.unlock(io);
        switch (result) {
            .new => |*token| {
                token.rid = id;
                id += 1;
                client = try ga.create(Client);
                client.init(&conn, token, aa);
                try state.tokens.append(state.ga, token.*);
                try state.links.put(token.rid.?, .init(state.ga, utils.usizeCmp));
                try state.clients.append(state.ga, client);
            },
            .existing => |idx| {
                const token = &state.tokens.items[idx];
                if (token.rid == null) {
                    token.rid = id;
                    id += 1;
                }

                const client_idx: ?usize = for (state.clients.items, 0..) |c, i| {
                    if (c.rid == token.rid.?) break i;
                } else null;
                if (client_idx) |cidx| {
                    client = state.clients.items[cidx];
                    client.conn = conn;
                    client.online = true;
                    client.active_mutex = .init;
                    client.writer_mutex = .init;
                } else {
                    client = try ga.create(Client);
                    client.init(&conn, token, aa);
                    try state.clients.append(state.ga, client);
                    try state.links.put(token.rid.?, .init(state.ga, utils.usizeCmp));
                }
            },
        }

        var conn_writer = conn.writer(io, &buf);
        const w = &conn_writer.interface;
        const init_pkt = try std.json.Stringify.valueAlloc(state.ga, Packet{
            .rid = client.rid,
            .data = .{ .init = client.name },
        }, .{ .whitespace = .indent_2 });
        defer ga.free(init_pkt);
        client.errWriteAll(w, init_pkt) orelse {
            client.online = false;
            continue;
        };
        client.errFlush(w) orelse {
            client.online = false;
            continue;
        };

        var present_links: std.ArrayList(types.Data.UpdateInfo.LinkType) = .empty;
        defer present_links.deinit(aa);
        for (state.clients.items) |c| {
            if (c == client) {
                @branchHint(.unlikely);
                continue;
            }
            if (c.online) {
                try c.writer_mutex.lock(io);
                defer c.writer_mutex.unlock(io);
                var cwriter = c.conn.writer(io, &buf);
                const cw = &cwriter.interface;
                try c.sendData(cw, .{
                    .new_user = .{
                        .rid = client.rid,
                        .name = client.name,
                        .online = true,
                    },
                }) orelse continue;
            }

            try client.sendData(w, .{
                .new_user = .{
                    .rid = c.rid,
                    .name = c.name,
                    .online = c.online,
                },
            }) orelse continue;

            if (state.links.getPtr(c.rid).?.find(client.rid) != null) {
                try present_links.append(aa, .{ .rid = c.rid });
            }
        }
        if (present_links.items.len > 0) try client.sendData(w, .{
            .update_user = .{
                .rid = client.rid,
                .links = present_links.items[0..present_links.items.len],
            },
        }) orelse continue;

        _ = try std.Thread.spawn(.{}, server_mod.handleClient, .{ client, &state });
    }
    try updateTokensFile(&state);
    info("Closing the server", .{});
}

fn populateTokens(state: *State) !void {
    const io = state.io;
    var buf: [1024]u8 = undefined;
    const token_file = try state.profile_dir.createFile(io, "tokens.json", .{ .truncate = false, .read = true });
    defer token_file.close(io);
    var token_file_r = token_file.reader(io, &buf);
    const reader = &token_file_r.interface;

    const file_size = (try token_file.stat(io)).size;
    if (file_size == 0) {
        info("Empty tokens file", .{});
        return;
    }
    const json_str = try reader.readAlloc(state.ga, file_size);
    defer state.ga.free(json_str);

    const parsed: std.json.Parsed([]Token) = try std.json.parseFromSlice([]Token, state.ga, json_str, .{});
    defer parsed.deinit();

    for (parsed.value) |*t| {
        try state.tokens.append(state.ga, .{
            .id = try state.ga.dupe(u8, t.id),
            .name = try state.ga.dupe(u8, t.name),
        });
    }
}

fn updateTokensFile(state: *State) !void {
    const io = state.io;
    const profile_dir = state.profile_dir;
    const tmp_file = try profile_dir.createFile(io, "tokens.json.tmp", .{});
    defer tmp_file.close(io);
    var buf: [1024]u8 = undefined;
    var writer_f = tmp_file.writer(io, &buf);
    const writer = &writer_f.interface;
    const tokens = state.tokens.items;

    const TokenFile = struct { id: []u8, name: []u8 };
    const tmp = try state.ga.alloc(TokenFile, tokens.len);
    defer state.ga.free(tmp);

    for (tokens, 0..) |*t, i| {
        tmp[i] = .{ .id = t.id, .name = t.name };
    }
    try std.json.Stringify.value(tmp, .{ .whitespace = .indent_2 }, writer);
    try writer.writeAll("\n");
    try writer.flush();
    try profile_dir.rename("tokens.json.tmp", profile_dir, "tokens.json", io);
}

const std = @import("std");
const net = std.Io.net;
const posix = std.posix;
const linux = std.os.linux;
const bufPrint = std.fmt.bufPrint;
const info = std.log.info;
const types = @import("types");
const State = types.Server;
const Client = State.Client;
const Token = types.Token;
const Set = types.Set;
const Packet = types.Packet;
const server_mod = @import("server");
const utils = @import("utils");
const checkLock = utils.checkLock;
