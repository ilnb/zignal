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

pub fn parsePacket(state: *State, msg: []const u8) !?Packet {
    var itr = std.mem.tokenizeScalar(u8, msg, ' ');

    const header = itr.next() orelse return null;
    if (eql(u8, header, "ECHO")) {
        const to_echo = itr.rest();
        return Packet{
            .rid = state.rid,
            .data = .{
                .echo = try state.aa.dupe(u8, to_echo),
            },
        };
    } else if (eql(u8, header, "WHOAMI")) {
        return Packet{
            .rid = state.rid,
            .data = .{
                .name = state.name,
            },
        };
    } else if (eql(u8, header, "NAME")) {
        const name = itr.next() orelse return Packet{
            .rid = state.rid,
            .data = .{
                .err = try state.aa.dupe(u8, "No id or name specified."),
            },
        };
        var num_count: usize = 0;
        for (name) |c| {
            if (c >= '0' and c <= '9') num_count += 1;
        }
        if (num_count == name.len) return Packet{
            .rid = state.rid,
            .data = .{
                .err = try state.aa.dupe(u8, "All numeric name is not allowed."),
            },
        };
        if (eql(u8, name, state.name)) return null;
        return Packet{
            .rid = state.rid,
            .data = .{
                .name = try state.aa.dupe(u8, name),
            },
        };
    } else if (eql(u8, header, "LINK")) {
        const buf = itr.next() orelse return Packet{
            .rid = state.rid,
            .data = .{
                .err = try state.aa.dupe(u8, "No id or name specified."),
            },
        };
        if (eql(u8, buf, state.name) or std.fmt.parseInt(usize, buf, 10) catch std.math.maxInt(usize) == state.rid) return Packet{
            .rid = state.rid,
            .data = .{
                .err = try state.aa.dupe(u8, "Self link."),
            },
        };
        return Packet{
            .rid = state.rid,
            .data = .{
                .link = .{
                    .with = try state.aa.dupe(u8, buf),
                },
            },
        };
    } else if (eql(u8, header, "UNLINK")) {
        const buf = itr.next() orelse return Packet{
            .rid = state.rid,
            .data = .{
                .err = try state.aa.dupe(u8, "No id or name specified."),
            },
        };
        if (eql(u8, buf, state.name) or std.fmt.parseInt(usize, buf, 10) catch std.math.maxInt(usize) == state.rid) return Packet{
            .rid = state.rid,
            .data = .{
                .err = try state.aa.dupe(u8, "Self unlink."),
            },
        };
        return Packet{
            .rid = state.rid,
            .data = .{
                .link = .{
                    .with = try state.aa.dupe(u8, buf),
                    .invert = true,
                },
            },
        };
    } else if (eql(u8, header, "SENDTO")) {
        const buf = itr.next() orelse return Packet{
            .rid = state.rid,
            .data = .{
                .err = try state.aa.dupe(u8, "No id or name specified."),
            },
        };
        const to_send = std.mem.trim(u8, itr.rest(), " \n");
        if (to_send.len == 0) return Packet{
            .rid = state.rid,
            .data = .{
                .err = "Nothing to send.",
            },
        };
        if (eql(u8, buf, state.name) or std.fmt.parseInt(usize, buf, 10) catch std.math.maxInt(usize) == state.rid) return Packet{
            .rid = state.rid,
            .data = .{
                .err = try state.aa.dupe(u8, "Self message."),
            },
        };
        return Packet{
            .rid = state.rid,
            .data = .{
                .msg = .{
                    .peer = try state.aa.dupe(u8, buf),
                    .buf = try state.aa.dupe(u8, to_send),
                },
            },
        };
    } else if (eql(u8, header, "ALL")) {
        const to_send = std.mem.trim(u8, itr.rest(), " \n");
        return Packet{
            .rid = state.rid,
            .data = .{
                .msg = .{
                    .buf = try state.aa.dupe(u8, to_send),
                },
            },
        };
    } else if (eql(u8, header, "GETINFO")) {
        var arr: std.ArrayList([]u8) = .empty;
        var bitr = std.mem.tokenizeScalar(u8, itr.rest(), ' ');
        while (bitr.next()) |to_fetch| try arr.append(state.aa, try state.aa.dupe(u8, to_fetch));
        return Packet{
            .rid = state.rid,
            .data = .{
                .to_get = try arr.toOwnedSlice(state.aa),
            },
        };
    } else return Packet{
        .rid = state.rid,
        .data = .{
            .err = try allocPrint(state.aa, "Invalid cmd {s}.", .{header}),
        },
    };
}

pub fn formatUsers(state: *const State, users: []const Packet.Infos) ![]u8 {
    const rid = state.rid;
    const aa = state.aa;

    var id_w: usize = 0;
    var name_w: usize = "NAME".len;
    for (users) |*u| {
        id_w = @max(id_w, std.fmt.count("{d}", .{u.rid}));
        name_w = @max(name_w, u.name.len);
    }
    id_w += 2;
    if (name_w == "NAME".len) name_w += 1;
    name_w += 2;

    var msg: std.ArrayList(u8) = try .initCapacity(aa, users.len);
    errdefer msg.deinit(aa);

    var res = try allocPrint(aa, "{s: <[2]}{s: <[3]}LINK\n", .{ "ID", "NAME", id_w, name_w });
    try msg.appendSlice(aa, res);
    aa.free(res);

    for (users) |*u| {
        var name_buf: [256]u8 = undefined;
        const name = if (u.rid == rid)
            std.fmt.bufPrint(&name_buf, "{s}*", .{u.name}) catch u.name
        else
            u.name;

        res = try allocPrint(aa, "{d: <[2]}{s: <[3]}", .{ u.rid, name, id_w, name_w });
        try msg.appendSlice(aa, res);
        aa.free(res);

        var i: usize = 1;
        for (u.links) |link| {
            res = try std.fmt.allocPrint(aa, "{d}{s}", .{ link, if (i != u.links.len) ", " else "" });
            try msg.appendSlice(aa, res);
            aa.free(res);
            i += 1;
        }
        try msg.append(aa, '\n');
    }

    if (msg.items.len > 0) _ = msg.pop();
    return msg.toOwnedSlice(aa);
}

const std = @import("std");
const net = std.Io.net;
const bufPrint = std.fmt.bufPrint;
const types = @import("types");
const Packet = types.Packet;
const PacketType = types.PacketType;
const State = types.CClient;
const utils = @import("utils");
const checkLock = utils.checkLock;
const eql = std.mem.eql;
const allocPrint = std.fmt.allocPrint;
