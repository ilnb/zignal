const G = struct {
    var running = std.atomic.Value(bool).init(true);
    var stream: net.Stream = undefined;
    var io: Io = undefined;
};

pub fn handleSig(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    if (!G.running.swap(false, .acq_rel)) return;
    G.stream.shutdown(G.io, .recv) catch {};
}

pub fn main(init: std.process.Init) !void {
    G.io = init.io;
    const aa = init.arena.allocator();
    const ga = init.gpa;
    const args = try init.minimal.args.toSlice(aa);

    var profile: []const u8 = "default";
    var port: u16 = 8000;
    const help_msg =
        \\Usage:
        \\ -h, --help            Display help
        \\ -p, --port <num>      Specify port, defaults to 8000
        \\ -P, --profile <name>  Specify profile, defaults to "default"
    ;

    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--profile") or
                std.mem.eql(u8, args[i], "-P"))
            {
                if (i + 1 == args.len) {
                    std.debug.print("Missing profile name. Try -h for more information.\n", .{});
                    return;
                }
                i += 1;
                profile = args[i];
            } else if (std.mem.eql(u8, args[i], "--port") or
                std.mem.eql(u8, args[i], "-p"))
            {
                if (i + 1 == args.len) {
                    std.debug.print("Missing port number. Try -h for more information.\n", .{});
                    return;
                }
                i += 1;
                port = std.fmt.parseInt(u16, args[i], 10) catch |err| {
                    std.debug.print("Error when parsing port number: {any}\n", .{err});
                    return;
                };
            } else if (std.mem.eql(u8, args[i], "--help") or
                std.mem.eql(u8, args[i], "-h"))
            {
                std.debug.print("{s}\n", .{help_msg});
                return;
            } else {
                std.debug.print("Invalid flag. {s}\n", .{help_msg});
                return;
            }
        }
    }

    const home = init.environ_map.get("HOME").?;
    var home_dir = try std.Io.Dir.openDirAbsolute(G.io, home, .{});
    defer home_dir.close(G.io);

    var buf: [128]u8 = undefined;
    const profile_path = try std.fmt.bufPrint(&buf, ".config/zignal/client/{s}", .{profile});
    var profile_dir = try home_dir.createDirPathOpen(G.io, profile_path, .{});
    defer profile_dir.close(G.io);

    utils.checkLock(init.io, &profile_dir) catch |err| {
        if (err != error.EndOfStream) {
            std.debug.print("Lock check failed with error: {any}\n", .{err});
        }
        return;
    };
    const lock_file = try profile_dir.createFile(G.io, "lock", .{});
    defer profile_dir.deleteFile(G.io, "lock") catch {};
    defer lock_file.close(G.io);

    const pid = std.os.linux.getpid();
    const pid_sl = try std.fmt.bufPrint(&buf, "{d}", .{pid});
    try lock_file.writeStreamingAll(G.io, pid_sl);

    const addr = net.IpAddress{ .ip4 = net.Ip4Address.unspecified(port) };
    G.stream = try addr.connect(G.io, .{ .mode = .stream, .protocol = .tcp });

    var wbuf: [1024]u8 = undefined;
    var writer_file = G.stream.writer(G.io, &wbuf);
    const writer = &writer_file.interface;

    var rbuf: [1024]u8 = undefined;
    var reader_file = G.stream.reader(G.io, &rbuf);
    const reader = &reader_file.interface;

    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSig },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.HUP, &sa, null);

    client_mod.handshakeWithServer(&init, profile_dir, &G.stream) catch |err| {
        std.debug.print("Handshake failed with {any}.\n", .{err});
        return;
    };

    var ui = UI{
        .w = 1000,
        .h = 700,
        .user_box = .{
            .w = 250,
            .h = 45,
            .top_gap = 10,
        },
        .chat_win = .{
            .bg = .{ .r = 0x15, .g = 0x15, .b = 0x15 },
            .font_color = .{ .r = 0xc8, .g = 0xc4, .b = 0xaa },
        },
        .bg = .{ .r = 0x15, .g = 0x15, .b = 0x15 },
        .font_color = .{ .r = 0xc8, .g = 0xc4, .b = 0xaa },
        .sep_color = .{ .r = 0x30, .g = 0x30, .b = 0x30 },
    };
    ui.chat_win.x = ui.user_box.w + ui.sep_width;
    ui.chat_win.w = ui.w - ui.chat_win.x;
    ui.chat_win.h = ui.h - ui.chat_win.input_box.h;
    ui.chat_win.input_box.w = ui.chat_win.w - 3 * ui.chat_win.pad - 2 * ui.chat_win.send_r;

    if (!sdl.init(sdl.INIT_VIDEO)) {
        std.debug.print("Failed to init sdl window: {s}\n", .{sdl.getError() orelse "Unknown"});
        return;
    }
    defer sdl.quit();

    if (!sdl.ttfInit()) {
        std.debug.print("Failed to init.ttf: {s}\n", .{sdl.getError() orelse "Unknown"});
        return;
    }
    defer sdl.ttfQuit();

    const font_path = "font/MapleMono-CN-Regular.ttf";
    ui.font = sdl.openFont(font_path, ui.user_box.font_size) orelse {
        std.debug.print("Failed to load font: {s}\n", .{sdl.getError() orelse "Unknown"});
        return;
    };
    defer sdl.closeFont(ui.font);

    const g_window = sdl.createWindow("zignal client", @intCast(ui.w), @intCast(ui.h), 0) orelse {
        std.debug.print("Failed to create window: {s}\n", .{sdl.getError() orelse "Unknown"});
        return;
    };
    defer sdl.destroyWindow(g_window);

    const g_renderer = sdl.createRenderer(g_window, null) orelse {
        std.debug.print("Failed to init renderer for main window: {s}\n", .{sdl.getError() orelse "Unknown"});
        return;
    };
    defer sdl.destroyRenderer(g_renderer);

    var state = State{
        .aa = aa,
        .ga = ga,
        .io = init.io,
        .cset = .init(ga, utils.usizeCmp),
        .pset = types.Set(State.PktMsgMap).init(ga, struct {
            fn cmp(a: State.PktMsgMap, b: State.PktMsgMap) std.math.Order {
                return std.math.order(a.id, b.id);
            }
        }.cmp),
    };
    defer state.deinit();

    const RECV_EVENT = sdl.registerEvents(1);
    const recv_thread = std.Thread.spawn(.{}, recvFn, .{ reader, &state, RECV_EVENT }) catch |err| {
        std.debug.print("Error when trying to spawn thread: {any}\n", .{err});
        return;
    };
    defer recv_thread.join();

    var keys_held = [_]bool{false} ** 512;
    const sep_rect: sdl.FRect = .{
        .x = @floatFromInt(ui.user_box.w),
        .w = @floatFromInt(ui.sep_width),
        .h = @floatFromInt(ui.h),
    };

    // // Performance test: count frames
    // var frame_count: u32 = 0;
    // const start_time = sdl.getTicks();

    while (G.running.load(.acquire)) {
        var ev: sdl.Event = undefined;
        while (sdl.pollEvent(&ev)) {
            switch (ev.type) {
                sdl.EVENT_QUIT => {
                    G.running.store(false, .release);
                    try G.stream.shutdown(G.io, .recv);
                },

                sdl.EVENT_MOUSE_MOTION => {
                    ui.cursor = .{
                        .x = ev.motion.x,
                        .y = ev.motion.y,
                    };
                },

                sdl.EVENT_MOUSE_BUTTON_DOWN => {
                    const mx: usize = @floor(@max(0.0, ui.cursor.x));
                    const my: usize = @floor(@max(0.0, ui.cursor.y));
                    const len = state.clients.items.len;
                    if (mx < ui.user_box.w) {
                        const upad = ui.user_box.pad;
                        if (mx < upad or mx > ui.user_box.w - upad) {
                            @branchHint(.unlikely);
                            ui.mouse = .on_list;
                            continue;
                        }
                        const idx: usize = @as(usize, @intCast(@as(i32, @intCast(my)) + ui.user_box.scroll)) / ui.user_box.h;
                        if (idx >= len) {
                            ui.curr_user = null;
                            ui.mouse = .on_list;
                            continue;
                        }
                        const vdiff: usize = my - idx * ui.user_box.h;
                        if (upad <= vdiff and vdiff <= ui.user_box.h - upad) {
                            ui.curr_user = idx;
                            ui.mouse = if (state.clients.items[idx].connected) .input else .to_link;
                        } else {
                            ui.curr_user = null;
                            ui.mouse = .on_list;
                        }
                    } else {
                        const mwin_x, const mwin_y = .{ mx - ui.user_box.w, my };
                        const chat_h, const chat_w = .{ ui.chat_win.h, ui.chat_win.w };
                        const wpad = ui.chat_win.pad;
                        const send_r = ui.chat_win.send_r;
                        const input_w = ui.chat_win.input_box.w;

                        if (ui.mouse == .to_link) {
                            // TODO: check for link button
                        } else if (mwin_y >= chat_h + wpad and mwin_y <= ui.h - wpad) {
                            if ((mwin_x < wpad or
                                (mwin_x >= input_w - wpad and mwin_x < input_w) or
                                mwin_x >= chat_w - send_r) and
                                ui.curr_user != null)
                            {
                                ui.mouse = .on_chat;
                            } else if (mwin_x >= input_w and mwin_x < chat_w - send_r) {
                                const c = &state.clients.items[ui.curr_user.?];

                                const ibuf = c.input.items;
                                const ilen = ibuf.len;
                                if (ilen == 0) continue;

                                var rid_buf: [32]u8 = undefined;
                                try state.sendData(writer, .{
                                    .msg = .{
                                        .peer = try std.fmt.bufPrint(&rid_buf, "{d}", .{c.rid}),
                                        .buf = ibuf[0..ilen],
                                    },
                                }) orelse break;

                                c.input.shrinkRetainingCapacity(0);
                            } else {
                                ui.mouse = .input;
                                _ = sdl.startTextInput(g_window);
                            }
                        } else {
                            ui.mouse = .on_chat;
                        }
                    }
                },

                sdl.EVENT_KEY_DOWN => {
                    const sc = ev.key.scancode;
                    if (keys_held[@intCast(sc)]) continue;
                    keys_held[@intCast(sc)] = true;

                    lbl: switch (ui.mouse) {
                        .on_list => {},
                        .to_link => {},
                        .on_chat => {
                            ui.mouse = .input;
                            continue :lbl .input;
                        },
                        .input => {
                            const c = &state.clients.items[ui.curr_user.?];
                            switch (sc) {
                                sdl.SCANCODE_ESCAPE => {
                                    ui.mouse = .on_chat;
                                    _ = sdl.stopTextInput(g_window);
                                },
                                sdl.SCANCODE_BACKSPACE => {
                                    const txt = &c.input;
                                    // pop utf chars
                                    while (utils.back(txt.items)) |tc| {
                                        if (tc & 0xc0 != 0x80) break;
                                        _ = txt.pop();
                                    }
                                    if (txt.items.len > 0) _ = txt.pop();
                                },
                                else => {},
                            }
                        },
                    }
                },

                sdl.EVENT_KEY_UP => keys_held[@intCast(ev.key.scancode)] = false,

                sdl.EVENT_TEXT_INPUT => {
                    lbl: switch (ui.mouse) {
                        .on_list => {},
                        .to_link => {},
                        .on_chat => {
                            ui.mouse = .input;
                            continue :lbl .input;
                        },
                        .input => {
                            const text = std.mem.sliceTo(ev.text.text, 0);
                            const c = &state.clients.items[ui.curr_user.?];
                            try c.input.appendSlice(ga, text);
                        },
                    }
                },

                else => {
                    if (ev.type == RECV_EVENT) {
                        const ptr: [*]u8 = @ptrCast(ev.user.data1.?);
                        const len: usize = @intFromPtr(ev.user.data2.?);
                        const line = ptr[0..len];
                        defer state.ga.free(line);

                        const parsed_pkt = try std.json.parseFromSlice(Packet, aa, line, .{});
                        const parsed_value = parsed_pkt.value;
                        defer parsed_pkt.deinit();

                        switch (parsed_value.data) {
                            .init => |i| {
                                state.rid = parsed_value.rid;
                                state.name = try state.ga.dupe(u8, i);
                            },
                            .new_user => |n| {
                                if (state.cset.find(n.rid) != null) continue;
                                try state.cset.put(n.rid);

                                try state.clients.append(state.ga, .{
                                    .name = try state.ga.dupe(u8, n.name),
                                    .rid = n.rid,
                                    .online = n.online,
                                });
                            },
                            .msg => |m| {
                                var pitr = std.mem.splitScalar(u8, m.peer.?, ' ');
                                _ = pitr.next().?;
                                const brid = pitr.next().?;
                                const rid = try std.fmt.parseInt(usize, brid, 10);

                                const c: *Client = for (state.clients.items) |*c| {
                                    if (c.rid == rid) break c;
                                } else {
                                    std.debug.print("Client {d} not found\n", .{rid});
                                    continue;
                                };
                                try c.msgs.append(ga, .{
                                    .rid = rid,
                                    .buf = try ga.dupe(u8, m.buf),
                                    .id = 0,
                                    .state = .sent,
                                });
                            },
                            .err => |e| {
                                if (parsed_value.id) |id| {
                                    if (state.pset.find(.{ .id = id, .cid = 0, .mid = 0 })) |node| {
                                        const mapping = node.key;
                                        state.clients.items[mapping.cid].msgs.items[mapping.mid].state = .err;
                                        state.pset.remove(node.key);
                                    }
                                }
                                std.debug.print("Server error: {s}\n", .{e});
                            },
                            .ack => |id| {
                                if (state.pset.find(.{ .id = id, .cid = 0, .mid = 0 })) |node| {
                                    const mapping = node.key;
                                    state.clients.items[mapping.cid].msgs.items[mapping.mid].state = .sent;
                                    state.pset.remove(node.key);
                                }
                            },
                            .update_user => |u| {
                                if (u.rid == state.rid) {
                                    @branchHint(.unlikely);
                                    if (u.name) |n| {
                                        if (std.mem.eql(u8, state.name.?, n)) continue;
                                        ga.free(state.name.?);
                                        state.name = try ga.dupe(u8, n);
                                        std.debug.print("Updated name to {s}\n", .{state.name.?});
                                    }
                                    if (u.links) |links| {
                                        for (links) |l| {
                                            const c: *Client = for (state.clients.items) |*c| {
                                                if (c.rid == l.rid) break c;
                                            } else {
                                                std.debug.print("Client {d} not found\n", .{u.rid});
                                                continue;
                                            };
                                            c.connected = l.add;
                                            if (ui.curr_user) |idx| {
                                                if (state.clients.items[idx].rid == c.rid) {
                                                    if (l.add) {
                                                        ui.mouse = .input;
                                                        _ = sdl.startTextInput(g_window);
                                                        ui.text_cursor.visible = true;
                                                        ui.text_cursor.last_toggle = sdl.getTicks();
                                                    } else {
                                                        ui.mouse = .to_link;
                                                        _ = sdl.stopTextInput(g_window);
                                                    }
                                                }
                                            }
                                            std.debug.print("{s} {d}\n", .{ if (l.add) "Connected to" else "Disconnected from", c.rid });
                                        }
                                    }
                                } else {
                                    const c: *Client = for (state.clients.items) |*c| {
                                        if (c.rid == u.rid) break c;
                                    } else {
                                        std.debug.print("Client {d} not found\n", .{u.rid});
                                        continue;
                                    };

                                    if (u.name) |n| {
                                        if (std.mem.eql(u8, c.name, n)) continue;
                                        ga.free(c.name);
                                        c.name = try ga.dupe(u8, n);
                                        std.debug.print("updated name for {d}\n", .{c.rid});
                                    }
                                    if (u.online) |o| c.online = o;
                                }
                            },
                            else => {},
                        }
                    }
                },
            }
        }

        // clear the background
        _ = sdl.render.setDrawColor(g_renderer, ui.bg);
        _ = sdl.render.clear(g_renderer);

        // render clients list
        for (state.clients.items, 0..) |*c, i| {
            const crect = sdl.Rect{
                .x = 0,
                .y = @intCast(i * ui.user_box.h + ui.user_box.top_gap - ui.user_box.pad * @intFromBool(i != 0)),
                .h = @intCast(ui.user_box.h),
                .w = @intCast(ui.user_box.w),
            };
            const r_crect = gui.rectToFRect(crect);
            const crect_bg = if (sdl.pointInRect(&sdl.Point{
                .x = @trunc(ui.cursor.x),
                .y = @trunc(ui.cursor.y),
            }, &crect) or ui.curr_user != null and ui.curr_user.? == i)
                gui.modColor(ui.bg, 1.5)
            else
                ui.bg;

            const inner_color = gui.washColor(crect_bg, .{});
            const border_color = gui.washColor(crect_bg, .{ .n = 11 });
            _ = gui.drawBRect(
                g_renderer,
                &r_crect,
                @floatFromInt(ui.user_box.pad),
                border_color,
                inner_color,
            );

            const nulled_name = try aa.dupeZ(u8, c.name);
            defer aa.free(nulled_name);
            if (sdl.ttf.renderTextBlended(
                ui.font,
                nulled_name[0..c.name.len :0],
                c.name.len,
                ui.font_color,
            )) |surf| {
                defer sdl.surface.destroy(surf);
                if (sdl.createTextureFromSurface(g_renderer, surf)) |tex| {
                    defer sdl.destroyTexture(tex);

                    var tex_w: f32, var tex_h: f32 = .{ 0, 0 };
                    if (sdl.getTextureSize(tex, &tex_w, &tex_h)) {
                        const name_tex_rect = sdl.FRect{
                            .x = r_crect.x + 5,
                            .y = r_crect.y + (r_crect.h - tex_h) / 2,
                            .w = tex_w,
                            .h = tex_h,
                        };
                        _ = sdl.renderTexture(
                            g_renderer,
                            tex,
                            null,
                            &name_tex_rect,
                        );
                    }
                }
            }
        }

        switch (ui.mouse) {
            .input, .on_chat => {
                const chat_win = ui.chat_win;
                const input_box = sdl.FRect{
                    .x = @floatFromInt(chat_win.x),
                    .y = @floatFromInt(chat_win.h),
                    .w = @floatFromInt(chat_win.input_box.w),
                    .h = @floatFromInt(chat_win.input_box.h),
                };
                const inner_color = gui.washColor(ui.bg, .{ .n = 6 });
                const border_color = gui.washColor(ui.bg, .{ .n = 11 });
                _ = gui.drawBRect(
                    g_renderer,
                    &input_box,
                    @floatFromInt(chat_win.pad),
                    border_color,
                    inner_color,
                );
                const bordered_send = false;
                const send_bg_rect = sdl.FRect{
                    .x = @floatFromInt(chat_win.x + chat_win.input_box.w - chat_win.pad),
                    .y = input_box.y,
                    .w = @floatFromInt(2 * chat_win.pad + 2 * chat_win.send_r),
                    .h = input_box.h,
                };
                if (!bordered_send) {
                    _ = sdl.render.setDrawColor(g_renderer, border_color);
                    _ = sdl.render.fillRect(g_renderer, &send_bg_rect);
                } else {
                    _ = gui.drawBRect(
                        g_renderer,
                        &send_bg_rect,
                        @floatFromInt(chat_win.pad),
                        border_color,
                        inner_color,
                    );
                }
                _ = gui.drawCircle(g_renderer, @intCast(chat_win.x + (chat_win.w + chat_win.input_box.w) / 2), @intCast(chat_win.h - chat_win.input_box.h / 2), chat_win.send_r);
                // TODO: render messages
            },
            .to_link => {
                // TODO: print `to link` message
            },
            .on_list => {},
        }

        _ = sdl.render.setDrawColor(g_renderer, ui.sep_color);
        _ = sdl.render.rect(g_renderer, &sep_rect);

        _ = sdl.render.present(g_renderer);
        // frame_count += 1;
        // _ = sdl.delay(16);
    }

    // const end_time = sdl.getTicks();
    // const fps = @as(f32, @floatFromInt(frame_count)) / (@as(f32, @floatFromInt(end_time - start_time)) / 1000.0);
    // std.debug.print("Game loop ended. Average FPS: {d:.2}\n", .{fps});
}

fn recvFn(r: *Io.Reader, state: *State, recv_ev: c_uint) !void {
    const aa = state.ga;
    std.debug.print("recv thread started\n", .{});
    while (G.running.load(.acquire)) {
        std.debug.print("receiving a packet\n", .{});
        const slen = r.takeDelimiter(' ') catch |err| {
            std.debug.print("Error when receiving: {any}\n", .{err});
            G.running.store(false, .release);
            break;
        } orelse {
            if (G.running.load(.acquire)) {
                std.debug.print("EOF\n", .{});
                G.running.store(false, .release);
            }
            break;
        };
        const len = try std.fmt.parseInt(usize, slen, 10);

        const line = r.readAlloc(aa, len) catch |err| {
            std.debug.print("Error when receiving: {any}\n", .{err});
            G.running.store(false, .release);
            break;
        };
        std.debug.print("got packet\n", .{});

        var ev: sdl.Event = undefined;
        ev.type = recv_ev;
        ev.user.data1 = line.ptr;
        ev.user.data2 = @ptrFromInt(line.len);

        _ = sdl.pushEvent(&ev);
    }
    std.debug.print("closing recv thread\n", .{});
}

const std = @import("std");
const info = std.log.info;
const Io = std.Io;
const net = Io.net;
const posix = std.posix;
const client_mod = @import("client");
const utils = @import("utils");
const sdl = @import("zsdl3");
const types = @import("types");
const Packet = types.Packet;
const PacketType = types.PacketType;
const State = types.GClient;
const Client = State.Client;
const gui = @import("gui");
const UI = gui.UI;
