const std = @import("std");
const net = std.net;
const posix = std.posix;
const bufPrint = std.fmt.bufPrint;
const info = std.log.info;
const types = @import("types");
const Client = types.Client;
const State = types.State;
const Token = types.Token;
const Set = types.Set;
const client_mod = @import("client");
const utils = @import("utils");
const getClientNameByToken = utils.getClientNameByToken;

var running = std.atomic.Value(bool).init(true);

pub fn handleSig(sig: i32) callconv(.c) void {
    _ = sig;
    running.store(false, .release);
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) std.testing.expect(false) catch @panic("FAILURE");
    }
    const ga = gpa.allocator();

    const args = try std.process.argsAlloc(ga);
    defer std.process.argsFree(ga, args);

    var profile: []const u8 = "default";
    var port: u16 = 8000;
    const help_msg =
        \\ -h, --help            Display help
        \\ -p, --port <num>      Specify port, defaults to 8000
        \\ -P, --profile <name>  Specify profile, defaults to "default"
    ;

    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--profile") or std.mem.eql(u8, args[i], "-P")) {
                if (i + 1 == args.len) {
                    std.debug.print("Missing profile name. Try -h for more information.\n", .{});
                    return;
                }
                i += 1;
                profile = args[i];
            } else if (std.mem.eql(u8, args[i], "--port") or std.mem.eql(u8, args[i], "-p")) {
                if (i + 1 == args.len) {
                    std.debug.print("Missing port number. Try -h for more information.\n", .{});
                    return;
                }
                i += 1;
                port = std.fmt.parseInt(u16, args[i], 10) catch |err| {
                    std.debug.print("Error when parsing port number: {any}\n", .{err});
                    return;
                };
            } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
                std.debug.print("{s}\n", .{help_msg});
            }
        }
    }

    var buf: [1024]u8 = undefined;

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    var home_dir = try std.fs.openDirAbsolute(home, .{});
    defer home_dir.close();

    const profile_path = try bufPrint(&buf, ".config/zignal/server/{s}", .{profile});
    try home_dir.makePath(profile_path);
    var profile_dir = try home_dir.openDir(profile_path, .{});
    defer profile_dir.close();

    const lock_file = profile_dir.createFile("lock", .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            info("An instance of server with profile {s} is already running. Terminating...", .{profile});
            return;
        },
        else => return err,
    };
    lock_file.close();
    defer profile_dir.deleteFile("lock") catch {};

    const addr = net.Address.initIp4(.{0} ** 4, port);

    var server = try addr.listen(.{});
    defer server.deinit();
    info("Server listening on port {d}", .{port});

    const timeout = posix.timeval{ .sec = 1, .usec = 0 };
    try posix.setsockopt(server.stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));

    var state = State{
        .clients = .empty,
        .links = std.AutoHashMap(usize, Set(usize)).init(ga),
        .ga = &ga,
        .mutex = .{},
        .tokens = .empty,
        .profile_dir = profile_dir,
    };
    defer {
        const aa = state.ga;
        const tokens = &state.tokens;
        const clients = &state.clients;
        const links = &state.links;
        for (tokens.items) |token| {
            aa.free(token.id);
            aa.free(token.name);
        }
        for (clients.items) |c| {
            c.active.deinit(aa.*);
            aa.destroy(c);
        }
        tokens.deinit(aa.*);
        clients.deinit(aa.*);
        var itr = links.iterator();
        while (itr.next()) |e| e.value_ptr.deinit();
        links.deinit();
    }

    try populateTokens(&state);

    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSig },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sa, null);

    var id: usize = 1;
    while (running.load(.acquire)) {
        const conn = server.accept() catch |err| switch (err) {
            error.WouldBlock => continue,
            else => {
                if (!running.load(.acquire)) break;
                return err;
            },
        };
        const no_timeout = posix.timeval{ .sec = 0, .usec = 0 };
        try posix.setsockopt(conn.stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(no_timeout));

        var result = client_mod.handshakeWithClient(conn, &state) catch |err| {
            info("Handshake failed with client {f} with error {any}. Terminating connection", .{ conn.address, err });
            var writer = conn.stream.writer(&buf);
            const interface = &writer.interface;
            try interface.print("{any}\n", .{err});
            try interface.flush();
            conn.stream.close();
            continue;
        };

        var client: *Client = undefined;

        switch (result) {
            .new => |*token| {
                token.rid = id;
                id += 1;
                client = try ga.create(Client);
                client.* = Client{
                    .id = token.rid,
                    .conn = conn,
                    .name = token.name,
                    .online = true,
                    .writer_mutex = .{},
                    .active = .empty,
                    .active_mutex = .{},
                };
                try appendTokenToFile(token, &state);
                try state.tokens.append(state.ga.*, token.*);
                try state.links.put(token.rid, .init(state.ga.*, utils.usizeCmp));
                try state.clients.append(state.ga.*, client);
            },
            .existing => |idx| {
                const token = &state.tokens.items[idx];
                if (token.rid == 0) {
                    token.rid = id;
                    id += 1;
                }
                const client_idx: usize = for (state.clients.items, 0..) |c, i| {
                    if (c.id == token.rid) break i;
                } else std.math.maxInt(usize);
                if (client_idx != std.math.maxInt(usize)) {
                    client = state.clients.items[client_idx];
                    client.conn = conn;
                    client.online = true;
                } else {
                    client = try ga.create(Client);
                    client.* = Client{
                        .id = token.rid,
                        .conn = conn,
                        .name = token.name,
                        .online = true,
                        .writer_mutex = .{},
                        .active = .empty,
                        .active_mutex = .{},
                    };
                    try state.clients.append(state.ga.*, client);
                    try state.links.put(token.rid, .init(state.ga.*, utils.usizeCmp));
                }
            },
        }

        _ = try std.Thread.spawn(.{}, client_mod.handleClient, .{ client, &state });
    }
    info("Closing the server", .{});
}

fn populateTokens(state: *State) !void {
    var buf: [1024]u8 = undefined;
    const token_file = try state.profile_dir.createFile("token", .{ .truncate = false, .read = true });
    defer token_file.close();
    var token_file_r = token_file.reader(&buf);
    const reader = &token_file_r.interface;

    while (reader.takeDelimiter('\n')) |nline| {
        if (nline == null) break;
        const line = nline.?;

        var itr = std.mem.splitScalar(u8, line, ' ');
        var token: Token = undefined;
        const id = itr.next() orelse {
            info("Corrupted token file\n", .{});
            return error.MissingId;
        };
        token.id = try state.ga.dupe(u8, id);

        const name = itr.next() orelse {
            info("Corrupted token file\n", .{});
            state.ga.free(token.id);
            return error.MissingName;
        };
        token.name = try state.ga.dupe(u8, name);
        token.rid = 0;

        try state.tokens.append(state.ga.*, token);
    } else |err| {
        info("Error when reading tokens: {any}", .{err});
        return;
    }
}

fn appendTokenToFile(token: *Token, state: *State) !void {
    state.mutex.lock();
    defer state.mutex.unlock();
    const token_file = try state.profile_dir.createFile("token", .{ .truncate = false });
    defer token_file.close();
    try token_file.seekFromEnd(0);

    var buf: [128]u8 = undefined;
    var token_file_w = token_file.writer(&buf);
    const writer = &token_file_w.interface;
    try writer.print("{s} {s}\n", .{ token.id, token.name });
    try writer.flush();
}
