const std = @import("std");
const info = std.log.info;
const net = std.net;
const posix = std.posix;
const types = @import("types");
const Client = types.Client;
const State = types.State;
const Set = types.Set;
const client_mod = @import("client_mod");
const utils = @import("utils");

var running = std.atomic.Value(bool).init(true);

pub fn handleSig(sig: i32) callconv(.c) void {
    _ = sig;
    std.process.exit(0);
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

    const port = if (args.len == 1) 8000 else if (args.len == 2) try std.fmt.parseInt(u16, args[1], 10) else {
        std.debug.print("args.len > 2", .{});
        return;
    };

    const addr = net.Address.initIp4(.{0} ** 4, port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    info("Server listening on port {d}", .{port});

    var state = State{
        .clients = .empty,
        .links = std.AutoHashMap(usize, Set(usize)).init(ga),
        .ga = &ga,
        .mutex = .{},
    };
    defer {
        state.clients.deinit(ga);
        var itr = state.links.iterator();
        while (itr.next()) |e| e.value_ptr.deinit();
        state.links.deinit();
    }

    var id: usize = 0;

    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSig },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sa, null);

    while (running.load(.acquire)) {
        const conn = server.accept() catch |err| {
            if (!running.load(.acquire)) break;
            return err;
        };
        const client = try ga.create(Client);
        client.* = Client{
            .id = id,
            .conn = conn,
            .name = null,
            .writer_mutex = .{},
            .active = .empty,
            .active_mutex = .{},
        };

        try state.clients.append(ga, client);
        try state.links.put(id, .init(ga, utils.usizeCmp));

        _ = try std.Thread.spawn(.{}, client_mod.handleClient, .{ client, &state });
        id += 1;
    }
    info("Closing the server", .{});
}
