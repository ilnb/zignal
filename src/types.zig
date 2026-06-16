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
    link,
    msg,
    users,
    to_get,
    err,
};

pub const Packet = struct {
    const Info = GClient.Info;
    pub const Infos = struct {
        rid: usize,
        name: []u8,
        links: []usize,
    };
    pub const Data = union(PacketType) {
        echo: []const u8,
        init: []u8,
        name: []u8,
        new_user: Info,
        link: struct {
            with: []u8,
            invert: bool = false,
        },
        msg: struct {
            peer: ?[]u8 = null,
            buf: []u8,
        },
        users: []Infos,
        to_get: [][]u8,
        err: []const u8,
    };

    rid: usize,
    data: Data,
};

pub const Server = struct {
    const Self = @This();
    pub const SClient = struct {
        rid: usize,
        conn: net.Stream,
        name: []u8, // non owning ref
        online: bool = true,
        writer_mutex: Mutex = .init,
        active: AL(*SClient) = .empty,
        active_mutex: Mutex = .init,
        ga: Allocator,

        pub fn init(self: *SClient, conn: *const net.Stream, token: *Token, aa: Allocator) void {
            self.* = .{
                .rid = token.rid.?,
                .conn = conn.*,
                .name = token.name,
                .ga = aa,
            };
        }

        pub inline fn errWrite(self: *const SClient, w: *Writer, comptime fmt: []const u8, args: anytype) ?void {
            const res = std.fmt.allocPrint(self.ga, fmt, args) catch |err| {
                info("Write failed to {d}: {any}", .{ self.rid, err });
                return null;
            };
            defer self.ga.free(res);
            self.errWriteAll(w, res) orelse return;
        }

        pub inline fn errWriteAll(self: *const SClient, w: *Writer, msg: []const u8) ?void {
            w.print("{d} {s}", .{ msg.len, msg }) catch |err| {
                info("Write failed to {d}: {any}", .{ self.rid, err });
                return null;
            };
        }

        pub inline fn errFlush(self: *const SClient, w: *Writer) ?void {
            w.flush() catch |err| {
                info("Flush failed to {d}: {any}", .{ self.rid, err });
                return null;
            };
        }

        pub fn sendData(self: *const SClient, w: *Writer, data: Packet.Data) !?void {
            const msg = try std.json.Stringify.valueAlloc(self.ga, Packet{
                .rid = self.rid,
                .data = data,
            }, .{ .whitespace = .indent_2 });
            defer self.ga.free(msg);
            self.errWriteAll(w, msg) orelse return null;
            self.errFlush(w) orelse return null;
        }

        pub fn wSendData(ga: Allocator, w: *Writer, data: Packet.Data) !?void {
            const rid = std.math.maxInt(usize);
            const msg = try std.json.Stringify.valueAlloc(ga, Packet{
                .rid = rid,
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

    clients: AL(*SClient) = .empty,
    links: HM(usize, Set(usize)),
    mutex: Mutex = .init,
    profile_dir: Io.Dir,
    tokens: AL(Token) = .empty,
    ga: Allocator,
    aa: Allocator,
    io: Io,

    pub fn deinit(self: *Self) void {
        const aa = self.ga;
        const tokens = &self.tokens;
        const clients = &self.clients;
        const links = &self.links;
        for (tokens.items) |token| {
            aa.free(token.id);
            aa.free(token.name);
        }
        for (clients.items) |c| {
            c.active.deinit(aa);
            aa.destroy(c);
        }
        tokens.deinit(aa);
        clients.deinit(aa);
        var itr = links.iterator();
        while (itr.next()) |e| e.value_ptr.deinit();
        links.deinit();
    }
};

pub const CClient = struct {
    rid: usize = undefined,
    name: []u8 = undefined,
    aa: Allocator,
    io: Io,
};

pub const GClient = struct {
    const Self = @This();
    pub const Client = struct {
        connected: bool,
        title: []u8,
        rid: usize,
        msgs: AL(Msg),
        input: AL(u8),
    };
    pub const Info = struct { rid: usize, name: []u8 };
    pub const Msg = struct { rid: usize, buf: []u8 };

    name: ?[]u8 = null,
    clients: AL(Client) = .empty,
    clients_mutex: Mutex = .init,
    ga: Allocator,
    io: Io,

    pub fn deinit(self: *Self) void {
        const aa = self.ga;
        if (self.name) |name| aa.free(name);
        for (self.clients.items) |*c| {
            aa.free(c.title);
            for (c.msgs.items) |*msg| aa.free(msg.buf);
            c.msgs.deinit(aa);
            c.input.deinit(aa);
        }
        self.clients.deinit(aa);
    }
};

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Mutex = Io.Mutex;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const info = std.log.info;
const AL = std.ArrayList;
const HM = std.AutoHashMap;
