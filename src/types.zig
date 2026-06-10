pub const Set = @import("avl").Set;

pub const Token = struct {
    id: []u8,
    rid: ?usize = null,
    name: []u8,
};

pub const ServState = struct {
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

        pub fn init(c: *Client, conn: *const net.Stream, token: *Token, aa: Allocator) void {
            c.* = .{
                .rid = token.rid.?,
                .conn = conn.*,
                .name = token.name,
                .online = true,
                .writer_mutex = .init,
                .active = .empty,
                .active_mutex = .init,
                .ga = aa,
            };
        }

        pub fn makeInitInfo(c: *Client, aa: Allocator) ![]u8 {
            const tmp = try aa.create(ClientState.Info);
            defer aa.destroy(tmp);
            tmp.* = .{ .rid = c.rid, .name = c.name };
            const msg = try std.json.Stringify.valueAlloc(aa, tmp, .{ .whitespace = .indent_2 });
            return msg;
        }

        pub fn sendInitInfo(c: *Client, w: *Writer, msg: []const u8) !void {
            c.errWriteAll(w, msg) orelse return;
            c.errFlush(w) orelse return;
        }

        pub fn errWrite(c: *Client, w: *Writer, comptime fmt: []const u8, args: anytype) ?void {
            const res = std.fmt.allocPrint(c.ga, fmt, args) catch |err| {
                info("Write failed to {d}: {any}", .{ c.rid, err });
                return null;
            };
            defer c.ga.free(res);
            c.errWriteAll(w, res) orelse return;
        }

        pub fn errWriteAll(c: *Client, w: *Writer, msg: []const u8) ?void {
            w.print("{d} {s}", .{ msg.len, msg }) catch |err| {
                info("Write failed to {d}: {any}", .{ c.rid, err });
                return null;
            };
        }

        pub fn errFlush(c: *Client, w: *Writer) ?void {
            w.flush() catch |err| {
                info("Flush failed to {d}: {any}", .{ c.rid, err });
                return null;
            };
        }
    };

    clients: AL(*Client),
    links: HM(usize, Set(usize)),
    mutex: Mutex,
    profile_dir: Io.Dir,
    tokens: AL(Token),
    ga: Allocator,
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

pub const ClientState = struct {
    const Self = @This();
    pub const Client = struct {
        connected: bool,
        title: []u8,
        rid: usize,
        msgs: AL(IdMessage),
        input: AL(u8),
    };
    pub const Info = struct { rid: usize, name: []u8 };
    pub const IdMessage = struct { rid: usize, buf: []u8 };

    curr_user: ?usize = null,
    clients: AL(Self.Client) = .empty,
    clients_mutex: Mutex = .init,
    ga: Allocator,
    io: Io,
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
