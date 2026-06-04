const std = @import("std");
const info = std.log.info;
const Io = std.Io;
const net = Io.net;
const File = Io.File;
const posix = std.posix;
const server_mod = @import("server");
const utils = @import("utils");
const UiState = @import("types").UiState;
var ui = UiState{};
const prompt = "➜ ";
const line_clear = "\r\x1b[2K";

var running = std.atomic.Value(bool).init(true);
var stream: net.Stream = undefined;
var io: Io = undefined;

pub fn handleSig(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    if (!running.swap(false, .acq_rel)) return;
    stream.shutdown(io, .recv) catch {};
    File.stdin().close(io);
}

pub fn main(init: std.process.Init) !void {
    io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

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
                return;
            } else {
                std.debug.print("Invalid flag. {s}\n", .{help_msg});
                return;
            }
        }
    }

    const home = init.environ_map.get("HOME").?;
    var home_dir = try std.Io.Dir.openDirAbsolute(io, home, .{});
    defer home_dir.close(io);

    var buf: [128]u8 = undefined;
    const profile_path = try std.fmt.bufPrint(&buf, ".config/zignal/client/{s}", .{profile});
    var profile_dir = try home_dir.createDirPathOpen(io, profile_path, .{});
    defer profile_dir.close(io);

    utils.checkLock(init.io, &profile_dir) catch |err| {
        if (err != error.EndOfStream) {
            std.debug.print("Lock check failed with error: {any}", .{err});
            return;
        }
    };
    const lock_file = try profile_dir.createFile(io, "lock", .{});
    defer profile_dir.deleteFile(io, "lock") catch {};
    defer lock_file.close(io);

    const pid = std.os.linux.getpid();
    const pid_sl = try std.fmt.bufPrint(&buf, "{d}", .{pid});
    try lock_file.writeStreamingAll(io, pid_sl);

    const addr = net.IpAddress{ .ip4 = net.Ip4Address.unspecified(port) };
    stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });

    var wbuf: [1024]u8 = undefined;
    var writer_file = stream.writer(io, &wbuf);
    const writer = &writer_file.interface;

    var rbuf: [1024]u8 = undefined;
    var reader_file = stream.reader(io, &rbuf);
    const reader = &reader_file.interface;

    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader = File.stdin().reader(io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSig },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.HUP, &sa, null);

    server_mod.handshakeWithServer(&init, profile_dir, &stream) catch |err| {
        std.debug.print("Handshake failed with {any}.\n", .{err});
        return;
    };

    const recv_thread = std.Thread.spawn(.{}, recvFn, .{ reader, stdout }) catch |err| {
        std.debug.print("Error when trying to spawn thread: {any}\n", .{err});
        return;
    };
    defer recv_thread.join();

    var fds = [_]posix.pollfd{
        .{ .fd = File.stdin().handle, .events = posix.POLL.IN, .revents = 0 },
    };
    while (running.load(.acquire)) {
        try ui.mutex.lock(io);
        const timeout = 50;
        while (ui.pending) {
            timedWait(&ui.cond, &ui.mutex, timeout) catch |err| {
                if (err == error.Timeout) ui.pending = false;
            };
        }
        if (!ui.prompt_vis) {
            try stdout.writeAll(prompt);
            try stdout.flush();
            ui.prompt_vis = true;
        }
        ui.mutex.unlock(io);

        fds[0].revents = 0;
        if (posix.poll(&fds, 100) catch break == 0) continue;
        if (fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
            running.store(false, .release);
            break;
        }
        if (fds[0].revents & posix.POLL.IN == 0) continue;

        const msg = stdin.takeDelimiter('\n') catch |err| {
            if (!running.load(.acquire)) break;
            return err;
        } orelse {
            running.store(false, .release);
            ui.cond.signal(io);
            try stream.shutdown(io, .recv);
            break;
        };

        if (msg.len > 0) {
            try ui.mutex.lock(io);
            ui.prompt_vis = false;
            ui.pending = true;
            ui.mutex.unlock(io);

            try writer.print("{s}\n", .{msg});
            try writer.flush();
        } else {
            try ui.mutex.lock(io);
            ui.prompt_vis = false;
            ui.mutex.unlock(io);
        }
    }
    try stdout.print("{s}Closing the client\n", .{line_clear});
    try stdout.flush();
}

fn timedWait(cond: *Io.Condition, mutex: *Io.Mutex, timeout_ms: i64) !void {
    var epoch = cond.epoch.load(.acquire);
    {
        const prev_state = cond.state.fetchAdd(.{ .waiters = 1, .signals = 0 }, .monotonic);
        std.debug.assert(prev_state.waiters < std.math.maxInt(u16));
    }
    mutex.unlock(io);
    defer mutex.lockUncancelable(io);

    const wall_clock = Io.Clock.awake;
    const now = Io.Clock.now(wall_clock, io);
    const deadline = now.addDuration(.fromMilliseconds(timeout_ms));

    const timeout = Io.Timeout{ .deadline = .{ .raw = deadline, .clock = wall_clock } };

    while (true) {
        const result = io.futexWaitTimeout(u32, &cond.epoch.raw, epoch, timeout);
        epoch = cond.epoch.load(.acquire);

        var prev_state = cond.state.load(.monotonic);
        while (prev_state.signals > 0) {
            prev_state = cond.state.cmpxchgWeak(prev_state, .{
                .waiters = prev_state.waiters - 1,
                .signals = prev_state.signals - 1,
            }, .acquire, .monotonic) orelse return;
        }

        result catch |err| {
            const state = cond.state.fetchSub(.{ .waiters = 1, .signals = 0 }, .monotonic);
            std.debug.assert(state.waiters > 0);
            return err;
        };
    }
}

fn recvFn(r: *Io.Reader, stdout: *Io.Writer) void {
    while (running.load(.acquire)) {
        const line = r.takeDelimiter('\n') catch {
            std.debug.print("{s}Server disconnected (Error)\n", .{line_clear});
            running.store(false, .release);
            ui.cond.signal(io);
            break;
        } orelse {
            if (running.load(.acquire)) {
                std.debug.print("{s}Server disconnected (EOF)\n", .{line_clear});
                running.store(false, .release);
                ui.cond.signal(io);
            }
            break;
        };

        ui.mutex.lock(io) catch |err| {
            std.debug.print("Recv thread not able to take ui mutex. Err: {any}", .{err});
            return;
        };
        defer {
            ui.pending = false;
            ui.cond.signal(io);
            ui.mutex.unlock(io);
        }

        if (line.len == 0) {
            if (ui.prompt_vis) {
                stdout.print("{s}{s}", .{ line_clear, prompt }) catch return;
            }
        } else if (ui.prompt_vis) {
            stdout.print("{s}{s}\n{s}", .{ line_clear, line, prompt }) catch return;
        } else {
            stdout.print("{s}\n", .{line}) catch return;
        }
        stdout.flush() catch return;
    }
}
