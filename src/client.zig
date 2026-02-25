const std = @import("std");
const info = std.log.info;
const net = std.net;
const posix = std.posix;
const types = @import("types");
const Client = types.Client;
const State = types.State;
const Set = types.Set;
const server = @import("server");
const recv = server.recv;
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

    var stream = try net.tcpConnectToAddress(addr);
    defer stream.close();

    var wbuf: [1024]u8 = undefined;
    var writer_file = stream.writer(&wbuf).file_writer;
    const writer = &writer_file.interface;

    var rbuf: [1024]u8 = undefined;
    var reader_file = stream.reader(&rbuf).file_reader;
    const reader = &reader_file.interface;

    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSig },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sa, null);

    const recv_thread = std.Thread.spawn(.{}, recvFn, .{ reader, stdout }) catch |err| {
        std.debug.print("Error when trying to spawn thread.\nErr: {any}\n", .{err});
        return;
    };
    defer recv_thread.join();

    while (running.load(.acquire)) {
        const msg = stdin.takeDelimiter('\n') catch |err| {
            if (!running.load(.acquire)) break;
            return err;
        };
        if (msg == null) continue;
        try writer.print("{s}\n", .{msg.?});
        try writer.flush();
    }
}

fn recvFn(r: *std.Io.Reader, stdout: *std.Io.Writer) void {
    while (running.load(.acquire)) {
        const line = r.takeDelimiter('\n') catch {
            std.debug.print("Server disconnected\n", .{});
            std.process.exit(0);
            return;
        };
        const l = line orelse {
            std.debug.print("Server disconnected\n", .{});
            std.process.exit(0);
            return;
        };
        stdout.print("{s}\n", .{l}) catch return;
        stdout.flush() catch return;
    }
}
