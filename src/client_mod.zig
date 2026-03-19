const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const types = @import("types");
const Client = types.Client;

pub fn handshakeWithServer(s: *std.net.Stream, profile: []const u8) !void {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    var pbuf: [1024]u8 = undefined;
    const profile_dir = try bufPrint(&pbuf, "{s}/.config/zignal/{s}", .{ home, profile });
    var buf: [1024]u8 = undefined;
    std.fs.makeDirAbsolute(profile_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const lock_file = std.fs.createFileAbsolute(try bufPrint(&buf, "{s}/lock", .{profile_dir}), .{ .exclusive = true }) catch |err| return err;
    lock_file.close();
    const token_path = try bufPrint(&buf, "{s}/token", .{profile_dir});
    var new_user = false;
    const token_file = blk: {
        break :blk std.fs.openFileAbsolute(token_path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => {
                try createToken(token_path);
                new_user = true;
                break :blk try std.fs.openFileAbsolute(token_path, .{ .mode = .read_only });
            },
            else => return err,
        };
    };
    defer token_file.close();
    var token_r = token_file.reader(buf[0..40]);
    const t_reader = &token_r.interface;
    const token = try t_reader.take(32);

    var s_writer_file = s.writer(buf[40..80]).file_writer;
    const s_writer = &s_writer_file.interface;
    try s_writer.print("{s} {s}\n", .{ if (new_user) "NEW" else "OLD", token });
    try s_writer.flush();

    var s_reader_file = s.reader(buf[80..]).file_reader;
    const s_reader = &s_reader_file.interface;
    const msg = try s_reader.takeDelimiter('\n') orelse return error.EOF;
    if (std.mem.eql(u8, "OK", msg)) return;
    std.debug.print("Handshake error: {s}\n", .{msg});
    return error.HandshakeFailed;
}

fn createToken(token_path: []const u8) !void {
    var buf: [64]u8 = undefined;
    const token_file = std.fs.openFileAbsolute(token_path, .{ .mode = .write_only }) catch |err| return err;
    defer token_file.close();
    var token_w = token_file.writer(&buf);
    const writer = &token_w.interface;
    std.crypto.random.bytes(buf[0..16]);
    var token_hex: [32]u8 = undefined;
    try bufPrint(&token_hex, "{}", .{std.fmt.bytesToHex(buf[0..16], .lower)});
    try writer.writeAll(&token_hex);
    try writer.flush();
}
