pub const Set = @import("avl").Set;

pub const Token = struct {
    id: []u8,
    rid: ?usize = null,
    name: []u8,
};

pub const PacketType = enum {
    echo,
    init,
    name,
    new_user,
    update_user,
    link,
    msg,
    users,
    to_get,
    err,
    ack,
};

pub const Data = union(PacketType) {
    const Info = GClient.Info;
    pub const Infos = struct {
        rid: usize,
        name: []u8,
        links: []usize,
        online: bool,
    };
    pub const UpdateInfo = struct {
        pub const LinkType = struct { add: bool = true, rid: usize };
        rid: usize,
        name: ?[]u8 = null,
        links: ?[]const LinkType = null,
        online: ?bool = null,
    };
    echo: []const u8,
    init: []u8,
    name: []u8,
    new_user: Info,
    update_user: UpdateInfo,
    link: struct {
        with: []u8,
        invert: bool = false,
    },
    msg: struct {
        peer: ?[]u8 = null,
        buf: []const u8,
    },
    users: []Infos,
    to_get: [][]u8,
    err: []const u8,
    ack: usize,
};

pub const Packet = struct {
    rid: usize,
    id: ?usize = null,
    data: Data,
};

pub const Server = struct {
    const Self = @This();
    pub const Client = struct {
        rid: usize,
        conn: net.Stream,
        name: []u8, // non owning ref
        online: bool = true,
        writer_mutex: Mutex = .init,
        active: AL(*Client) = .empty,
        active_mutex: Mutex = .init,
        ga: Allocator,

        pub inline fn init(self: *Client, conn: *const net.Stream, token: *const Token, aa: Allocator) void {
            self.* = .{
                .rid = token.rid.?,
                .conn = conn.*,
                .name = token.name,
                .ga = aa,
            };
        }

        pub inline fn errWrite(self: *const Client, w: *Writer, comptime fmt: []const u8, args: anytype) ?void {
            return errWrite_(self, w, fmt, args);
        }

        pub inline fn errWriteAll(self: *const Client, w: *Writer, msg: []const u8) ?void {
            return errWriteAll_(self, w, msg);
        }

        pub inline fn errFlush(self: *const Client, w: *Writer) ?void {
            return errFlush_(self, w);
        }

        pub inline fn sendData(self: *const Client, w: *Writer, data: Data, id: ?usize) !?void {
            return sendData_(self, w, data, id);
        }

        pub inline fn wSendData(ga: Allocator, w: *Writer, data: Data, id: ?usize) !?void {
            const rid = std.math.maxInt(usize);
            const msg = try std.json.Stringify.valueAlloc(ga, Packet{
                .rid = rid,
                .id = id,
                .data = data,
            }, .{ .whitespace = .indent_2 });
            defer ga.free(msg);
            w.print("{d} {s}", .{ msg.len, msg }) catch |err| {
                info("Write failed to {d}: {any}", .{ rid, err });
                return null;
            };
            w.flush() catch |err| {
                info("Flush failed to {d}: {any}", .{ rid, err });
                return null;
            };
        }
    };

    clients: AL(*Client) = .empty,
    links: HM(usize, Set(usize)),
    mutex: Mutex = .init,
    profile_dir: Io.Dir,
    tokens: AL(Token) = .empty,
    ga: Allocator,
    aa: Allocator,
    io: Io,

    pub inline fn deinit(self: *Self) void {
        const ga = self.ga;
        const tokens = &self.tokens;
        const clients = &self.clients;
        const links = &self.links;
        for (tokens.items) |token| {
            ga.free(token.id);
            ga.free(token.name);
        }
        for (clients.items) |c| {
            c.active.deinit(ga);
            ga.destroy(c);
        }
        tokens.deinit(ga);
        clients.deinit(ga);
        var itr = links.iterator();
        while (itr.next()) |e| e.value_ptr.deinit();
        links.deinit();
    }
};

pub const CClient = struct {
    pub const PendingReq = struct { id: usize, buf: []const u8 = "" };
    rid: usize = undefined,
    name: []u8 = undefined,
    cset: Set(PendingReq) = undefined,
    packet_id_counter: usize = 0,
    aa: Allocator,
    io: Io,
};

pub const GClient = struct {
    const Self = @This();
    pub const Client = struct {
        msgs: AL(Msg) = .empty,
        input: AL(u8) = .empty,
        cursor_idx: usize = 0,
        name: []u8,
        rid: usize,
        connected: bool = false,
        online: bool,
    };
    pub const Info = struct { rid: usize, name: []u8, online: bool };
    pub const MsgState = enum { pending, sent, err };
    pub const Msg = struct { rid: usize, buf: []u8, id: usize, state: MsgState = .sent };
    pub const PktMsgMap = struct { id: usize, cidx: usize, midx: usize };

    rid: usize = undefined,
    name: ?[]u8 = null,
    packet_id_counter: usize = 1,
    clients: AL(Client) = .empty,
    cset: HM(usize, usize),
    pset: Set(PktMsgMap) = undefined,
    aa: Allocator,
    ga: Allocator,
    io: Io,

    pub inline fn deinit(self: *Self) void {
        const aa = self.ga;
        if (self.name) |name| aa.free(name);
        self.cset.deinit();
        self.pset.deinit();
        for (self.clients.items) |*c| {
            aa.free(c.name);
            for (c.msgs.items) |*msg| aa.free(msg.buf);
            c.msgs.deinit(aa);
            c.input.deinit(aa);
        }
        self.clients.deinit(aa);
    }

    pub inline fn errWrite(self: *const Self, w: *Writer, comptime fmt: []const u8, args: anytype) ?void {
        return errWrite_(self, w, fmt, args);
    }

    pub inline fn errWriteAll(self: *const Self, w: *Writer, msg: []const u8) ?void {
        return errWriteAll_(self, w, msg);
    }

    pub inline fn errFlush(self: *const Self, w: *Writer) ?void {
        return errFlush_(self, w);
    }

    pub inline fn sendData(self: *const Self, w: *Writer, data: Data, id: ?usize) !?void {
        return sendData_(self, w, data, id);
    }
};

fn errWrite_(self: anytype, w: *Writer, comptime fmt: []const u8, args: anytype) ?void {
    var T = @TypeOf(self);
    const iT = @typeInfo(T);
    if (iT == .pointer) T = iT.pointer.child;

    var aa: Allocator = undefined;
    if (@hasField(T, "aa")) {
        aa = self.aa;
    } else if (@hasField(T, "ga")) {
        aa = self.ga;
    } else {
        @compileError("No aa or ga field for allocator");
    }

    const res = std.fmt.allocPrint(aa, fmt, args) catch |err| {
        info("Write failed to {d}: {any}", .{ self.rid, err });
        return null;
    };
    defer aa.free(res);
    self.errWriteAll(w, res) orelse return;
}

fn errWriteAll_(self: anytype, w: *Writer, msg: []const u8) ?void {
    w.print("{d} {s}", .{ msg.len, msg }) catch |err| {
        info("Write failed to {d}: {any}", .{ self.rid, err });
        return null;
    };
}

fn errFlush_(self: anytype, w: *Writer) ?void {
    w.flush() catch |err| {
        info("Flush failed to {d}: {any}", .{ self.rid, err });
        return null;
    };
}

fn sendData_(self: anytype, w: *Writer, data: Data, id: ?usize) !?void {
    comptime var T = @TypeOf(self);
    const iT = @typeInfo(T);
    if (iT == .pointer) T = iT.pointer.child;

    var aa: Allocator = undefined;
    if (@hasField(T, "aa")) {
        aa = self.aa;
    } else if (@hasField(T, "ga")) {
        aa = self.ga;
    } else {
        @compileError("No aa or ga field for allocator");
    }

    const msg = try std.json.Stringify.valueAlloc(aa, Packet{
        .rid = self.rid,
        .id = id,
        .data = data,
    }, .{ .whitespace = .indent_2 });
    defer aa.free(msg);
    self.errWriteAll(w, msg) orelse return null;
    self.errFlush(w) orelse return null;
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Mutex = Io.Mutex;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const info = std.log.info;
const AL = std.ArrayList;
const HM = std.AutoHashMap;
