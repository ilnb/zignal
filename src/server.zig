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

    var buf: [1024]u8 = undefined;

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    var home_dir = try std.fs.openDirAbsolute(home, .{});
    defer home_dir.close();

    const profile_path = try bufPrint(&buf, ".config/zignal/server/{s}", .{profile});
    try home_dir.makePath(profile_path);
    var profile_dir = try home_dir.openDir(profile_path, .{});

    const lock_file = profile_dir.createFile("lock", .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            info("An instance of server with profile {s} is already running. Terminating...", .{profile});
            return;
        },
        else => return err,
    };
    lock_file.close();
    defer profile_dir.close();
    defer profile_dir.deleteFile("lock") catch {};

    const addr = net.Address.initIp4(.{0} ** 4, port);

    var server = try addr.listen(.{ .reuse_address = true });
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
    };
    defer {
        for (state.tokens.items) |token| {
            state.ga.free(token.id);
            state.ga.free(token.name);
        }
        state.tokens.deinit(state.ga.*);
        state.clients.deinit(state.ga.*);
        var itr = state.links.iterator();
        while (itr.next()) |e| e.value_ptr.deinit();
        state.links.deinit();
    }

    try populateTokens(&state, profile_dir);

    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSig },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sa, null);

    var id: usize = 0;
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

        const new_client, var token = client_mod.handshakeWithClient(conn, &state) catch |err| {
            info("Handshake failed with client {f} with error {any}. Terminating connection", .{ conn.address, err });
            const writer = conn.stream.writer(&buf);
            var interface = writer.interface;
            try interface.print("{any}\n", .{err});
            try interface.flush();
            conn.stream.close();
            continue;
        };

        token.rid = id;

        const client = try ga.create(Client);
        client.* = Client{
            .id = id,
            .conn = conn,
            .name = token.name,
            .writer_mutex = .{},
            .active = .empty,
            .active_mutex = .{},
        };

        try state.clients.append(state.ga.*, client);
        if (new_client) try state.tokens.append(state.ga.*, token);
        try state.links.put(id, .init(state.ga.*, utils.usizeCmp));

        _ = try std.Thread.spawn(.{}, client_mod.handleClient, .{ client, &state });
        id += 1;
    }
    info("Closing the server", .{});
}

fn populateTokens(state: *State, profile_dir: std.fs.Dir) !void {
    var buf: [1024]u8 = undefined;
    const token_file = try profile_dir.createFile("token", .{ .truncate = false });
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

        try state.tokens.append(state.ga.*, token);
    } else |err| {
        info("Error when reading tokens: {any}", .{err});
        return;
    }
}
