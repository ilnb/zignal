const std = @import("std");
const eql = std.mem.eql;
const info = std.log.info;
const Writer = std.Io.Writer;
const types = @import("types");
const Client = types.Client;
const State = types.State;
const Token = types.Token;

pub fn usizeCmp(a: usize, b: usize) std.math.Order {
    return std.math.order(a, b);
}

pub fn errWrite(w: *Writer, comptime fmt: []const u8, args: anytype, client: *Client) ?void {
    w.print(fmt, args) catch |err| {
        info("Write failed to {d}: {any}", .{ client.id, err });
        return null;
    };
}

pub fn errFlush(w: *Writer, client: *Client) ?void {
    w.flush() catch |err| {
        info("Flush failed to {d}: {any}", .{ client.id, err });
        return null;
    };
}

pub fn getClientById(buf: []const u8, state: *State) ?*Client {
    const id = std.fmt.parseInt(u8, buf, 10) catch return null;
    return for (state.clients.items) |c| {
        if (c.id == id) break c;
    } else return null;
}

pub fn getClientByName(buf: []const u8, state: *State) ?*Client {
    return for (state.clients.items) |c| {
        if (eql(u8, c.name, buf)) break c;
    } else return null;
}

pub fn getClientNameByToken(state: *State, token: *Token) ?[]u8 {
    return for (state.tokens.items) |t| {
        if (t.id == token.id) break token.name;
    } else null;
}
