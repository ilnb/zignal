const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const types = @import("types");
const Client = types.Client;
const utils = @import("utils");
const checkLock = utils.checkLock;

pub fn handshakeWithServer(s: *std.net.Stream, profile: []const u8) !std.fs.Dir {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    var buf: [1024]u8 = undefined;
    var home_dir = try std.fs.openDirAbsolute(home, .{});
    defer home_dir.close();

    const profile_path = try bufPrint(&buf, ".config/zignal/client/{s}", .{profile});
    try home_dir.makePath(profile_path);
    var profile_dir = try home_dir.openDir(profile_path, .{});

    checkLock(&profile_dir) catch |err| return err;
    const lock_file = profile_dir.createFile("lock", .{ .truncate = true }) catch |err| return err;
    defer lock_file.close();

    const pid = std.os.linux.getpid();
    const pid_sl = try bufPrint(&buf, "{d}", .{pid});
    try lock_file.writeAll(pid_sl);

    // const token_file = profile_dir.openFile("token", .{ .mode = .read_write }) catch |err| switch (err) {
    //     error.FileNotFound => blk: {
    //         break :blk try profile_dir.createFile("token", .{ .truncate = false, .read = true });
    //     },
    //     else => return err,
    // };
    const token_file = profile_dir.createFile("token", .{ .truncate = false, .read = true }) catch |err| return err;
    defer token_file.close();

    const new_user = (try token_file.stat()).size == 0;
    if (new_user) {
        var token_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&token_bytes);
        const hex = std.fmt.bytesToHex(token_bytes, .lower);
        var token_w = token_file.writer(&buf);
        const writer = &token_w.interface;
        try writer.writeAll(&hex);
        try writer.flush();
        try token_file.seekTo(0);
    }

    var token_r = token_file.reader(buf[0..40]);
    const t_reader = &token_r.interface;
    const token = try t_reader.take(32);

    var s_writer_file = s.writer(buf[40..80]).file_writer;
    const s_writer = &s_writer_file.interface;
    try s_writer.print("{s} {s}\n", .{ if (new_user) "NEW" else "OLD", token });
    try s_writer.flush();

    var s_reader_file = s.reader(buf[80..]).file_reader;
    const s_reader = &s_reader_file.interface;
    const msg = try s_reader.takeDelimiter('\n') orelse return error.EndOfStream;
    if (std.mem.eql(u8, "OK", msg)) return profile_dir;
    std.debug.print("Handshake error: {s}.\n", .{msg});
    return error.HandshakeFailed;
}

fn createToken(token_file: std.fs.File) !void {
    var token_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&token_bytes);
    const hex = std.fmt.bytesToHex(token_bytes, .lower);
    var buf: [64]u8 = undefined;
    var token_w = token_file.writer(&buf);
    const writer = &token_w.interface;
    try writer.writeAll(&hex);
    try writer.flush();
}
