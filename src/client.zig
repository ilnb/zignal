const std = @import("std");
const info = std.log.info;
const net = std.net;
const posix = std.posix;
const server_mod = @import("server");

var running = std.atomic.Value(bool).init(true);
var stream: net.Stream = undefined;

pub fn handleSig(sig: i32) callconv(.c) void {
    _ = sig;
    running.store(false, .release);
    stream.close();
    std.fs.File.stdin().close();
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

    const addr = net.Address.initIp4(.{0} ** 4, port);

    stream = try net.tcpConnectToAddress(addr);

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

    var profile_dir = server_mod.handshakeWithServer(&stream, profile) catch |err| {
        std.debug.print("handshake error: {any}", .{err});
        return;
    };
    defer profile_dir.close();
    defer profile_dir.deleteFile("lock") catch {};

    const recv_thread = std.Thread.spawn(.{}, recvFn, .{ reader, stdout }) catch |err| {
        std.debug.print("Error when trying to spawn thread.\nErr: {any}\n", .{err});
        return;
    };
    defer recv_thread.join();

    while (running.load(.acquire)) {
        const msg = stdin.takeDelimiter('\n') catch |err| {
            if (!running.load(.acquire)) break;
            return err;
        } orelse continue;
        try writer.print("{s}\n", .{msg});
        try writer.flush();
    }
}

fn recvFn(r: *std.Io.Reader, stdout: *std.Io.Writer) void {
    while (running.load(.acquire)) {
        const line = r.takeDelimiter('\n') catch {
            std.debug.print("Server disconnected\n", .{});
            running.store(false, .release);
            return;
        };
        const l = line orelse continue;
        stdout.print("{s}\n", .{l}) catch return;
        stdout.flush() catch return;
    }
}
