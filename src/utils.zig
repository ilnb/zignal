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
        info("Write failed to {d}: {any}", .{ client.rid, err });
        return null;
    };
}

pub fn errWriteAll(w: *Writer, msg: []const u8, client: *Client) ?void {
    w.writeAll(msg) catch |err| {
        info("Write failed to {d}: {any}", .{ client.rid, err });
        return null;
    };
}

pub fn errFlush(w: *Writer, client: *Client) ?void {
    w.flush() catch |err| {
        info("Flush failed to {d}: {any}", .{ client.rid, err });
        return null;
    };
}

pub fn getClientById(buf: []const u8, state: *State) ?*Client {
    const id = std.fmt.parseInt(u8, buf, 10) catch return null;
    return for (state.clients.items) |c| {
        if (c.rid == id) break c;
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

pub fn checkLock(profile_dir: *std.fs.Dir) !void {
    const lock_file = profile_dir.openFile("lock", .{}) catch |err| {
        if (err == error.FileNotFound) return;
        std.debug.print("Error on lock file: {any}\n", .{err});
        return err;
    };
    defer lock_file.close();

    var buf: [16]u8 = undefined;
    const bytes = lock_file.readAll(&buf) catch |err| return err;
    const prev_pid = std.fmt.parseInt(std.os.linux.pid_t, buf[0..bytes], 10) catch return;

    std.posix.kill(prev_pid, 0) catch |err| {
        if (err == error.ProcessNotFound) return;
        return err;
    };

    std.debug.print("Another instance is running.\n", .{});
    return error.InstancePresent;
}
