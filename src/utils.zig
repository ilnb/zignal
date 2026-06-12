pub fn usizeCmp(a: usize, b: usize) std.math.Order {
    return std.math.order(a, b);
}

pub fn getClientById(state: *ServState, buf: []const u8) ?*SClient {
    const id = std.fmt.parseInt(u8, buf, 10) catch return null;
    return for (state.clients.items) |c| {
        if (c.rid == id) break c;
    } else null;
}

pub fn getClientByName(state: *ServState, buf: []const u8) ?*SClient {
    return for (state.clients.items) |c| {
        if (eql(u8, c.name, buf)) break c;
    } else null;
}

pub fn getClientNameByToken(state: *ServState, token: *Token) ?[]u8 {
    return for (state.tokens.items) |t| {
        if (t.id == token.id) break token.name;
    } else null;
}

pub fn checkLock(io: std.Io, profile_dir: *std.Io.Dir) !void {
    const lock_file = profile_dir.openFile(io, "lock", .{}) catch |err| {
        if (err == error.FileNotFound) return;
        std.debug.print("Error on lock file: {any}\n", .{err});
        return err;
    };
    defer lock_file.close(io);

    var buf: [16]u8 = undefined;
    const bytes = try lock_file.readStreaming(io, &.{&buf});
    const prev_pid = std.fmt.parseInt(std.os.linux.pid_t, buf[0..bytes], 10) catch return;

    std.posix.kill(prev_pid, @enumFromInt(0)) catch |err| {
        if (err == error.ProcessNotFound) return;
        return err;
    };

    return error.InstancePresent;
}

const std = @import("std");
const eql = std.mem.eql;
const info = std.log.info;
const Writer = std.Io.Writer;
const types = @import("types");
const ServState = types.ServState;
const SClient = ServState.Client;
const Token = types.Token;
