pub fn handshakeWithServer(init: *const std.process.Init, profile_dir: std.Io.Dir, s: *net.Stream) !void {
    const io = init.io;
    var buf: [1024]u8 = undefined;

    const token_file = try profile_dir.createFile(io, "token", .{ .truncate = false, .read = true });
    defer token_file.close(io);

    const new_user = (try token_file.stat(init.io)).size == 0;
    if (new_user) {
        var token_bytes: [16]u8 = undefined;
        io.random(&token_bytes);
        const hex = std.fmt.bytesToHex(token_bytes, .lower);
        var token_w = token_file.writer(io, &buf);
        const writer = &token_w.interface;
        try writer.writeAll(&hex);
        try writer.flush();
    }

    var token_r = token_file.reader(io, buf[0..40]);
    try token_r.seekTo(0);
    const t_reader = &token_r.interface;
    const token = try t_reader.take(32);

    var s_writer_file = s.writer(io, buf[40..80]);
    const s_writer = &s_writer_file.interface;
    try s_writer.print("{s} {s}\n", .{ if (new_user) "NEW" else "OLD", token });
    try s_writer.flush();

    var s_reader_file = s.reader(io, buf[80..]);
    const s_reader = &s_reader_file.interface;

    const slen = try s_reader.takeDelimiter(' ') orelse return error.ReadError;
    const len = try std.fmt.parseInt(usize, slen, 10);
    const msg = try s_reader.readAlloc(init.gpa, len);
    defer init.gpa.free(msg);

    if (std.mem.eql(u8, "OK", msg)) return;
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

const std = @import("std");
const net = std.Io.net;
const bufPrint = std.fmt.bufPrint;
const types = @import("types");
const SClient = types.ServState.Client;
const utils = @import("utils");
const checkLock = utils.checkLock;
