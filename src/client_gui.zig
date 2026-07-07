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

    client_mod.handshakeWithServer(&init, profile_dir, reader, writer) catch |err| {
        std.debug.print("Handshake failed with {any}.\n", .{err});
        return;
    };

    var ui = UI{
        .w = 1000,
        .h = 700,
        .user_box = .{
            .w = 250,
            .h = 45,
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

    var ignore_text_input = false;
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
                sdl.EVENT_MOUSE_WHEEL => {
                    const my = ev.wheel.y;
                    const scroll_speed: f32 = 30.0;
                    switch (ui.mouse) {
                        .on_list => {
                            ui.user_box.scroll = @max(0, ui.user_box.scroll + my * scroll_speed);
                        },
                        .on_chat => {
                            ui.chat_win.scroll = @max(0, ui.chat_win.scroll + my * scroll_speed);
                        },
                        .input => {
                            ui.chat_win.input_box.scroll = @max(0, ui.chat_win.input_box.scroll + my * scroll_speed);
                        },
                        else => {},
                    }
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
                                sdl.SCANCODE_RETURN => {
                                    if ((sdl.getModState() & sdl.keycode.KMOD_SHIFT) != 0) {
                                        c.input.append(ga, '\n') catch {};
                                    } else {
                                        const ibuf = c.input.items;
                                        const trimmed = std.mem.trim(u8, ibuf, " \n\r\t");
                                        if (trimmed.len > 0) {
                                            var rid_buf: [32]u8 = undefined;
                                            const pkt_id = state.packet_id_counter;
                                            state.packet_id_counter += 1;
                                            state.sendData(writer, .{
                                                .msg = .{
                                                    .peer = std.fmt.bufPrint(&rid_buf, "{d}", .{c.rid}) catch return,
                                                    .buf = trimmed,
                                                },
                                            }, pkt_id) catch return orelse break;
                                            c.msgs.append(ga, .{
                                                .rid = state.rid,
                                                .buf = ga.dupe(u8, trimmed) catch return,
                                                .id = pkt_id,
                                                .state = .pending,
                                            }) catch return;
                                            state.pset.put(.{ .id = pkt_id, .cid = ui.curr_user.?, .mid = c.msgs.items.len - 1 }) catch return;
                                            c.input.shrinkRetainingCapacity(0);
                                        } else {
                                            c.input.shrinkRetainingCapacity(0);
                                        }
                                    }
                                    ui.chat_win.input_box.scroll = 0;
                                },
                                else => {},
                            }
                        },
                    }
                },

                sdl.EVENT_KEY_UP => keys_held[@intCast(ev.key.scancode)] = false,

                sdl.EVENT_TEXT_INPUT => {
                    if (ignore_text_input) {
                        ignore_text_input = false;
                        continue;
                    }
                    lbl: switch (ui.mouse) {
                        .on_list => {},
                        .to_link => {},
                        .on_chat => {
                            ui.mouse = .input;
                            _ = sdl.startTextInput(g_window);
                            continue :lbl .input;
                        },
                        .input => {
                            const text = std.mem.sliceTo(ev.text.text, 0);
                            const c = &state.clients.items[ui.curr_user.?];
                            for (text) |ch| {
                                if (ch >= 32) try c.input.append(state.ga, ch);
                            }
                            ui.chat_win.input_box.scroll = std.math.floatMax(f32);
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
                .y = @as(c_int, @intCast(i * ui.user_box.h)) - @as(c_int, @intFromFloat(ui.user_box.scroll)) - @as(c_int, @intCast(ui.user_box.pad * @intFromBool(i != 0))),
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

        if (ui.curr_user) |c_idx| {
            const c = &state.clients.items[c_idx];
            const chat_win = ui.chat_win;
            if (!c.connected) {
                const btn_w = 200;
                const btn_h = 50;
                const bx = chat_win.x + (chat_win.w - btn_w) / 2;
                const by = (chat_win.h - btn_h) / 2;
                const btn_rect = sdl.FRect{
                    .x = @floatFromInt(bx),
                    .y = @floatFromInt(by),
                    .w = @floatFromInt(btn_w),
                    .h = @floatFromInt(btn_h),
                };
                const inner_color = gui.washColor(ui.bg, .{ .n = 8 });
                const border_color = gui.washColor(ui.bg, .{ .n = 12 });
                _ = gui.drawBRect(g_renderer, &btn_rect, 2.0, border_color, inner_color);

                renderTextCentered(g_renderer, ui.font, "Connect", ui.font_color, btn_rect);
            } else {
                const tb = chat_win.top_bar;
                const tb_rect = sdl.FRect{
                    .x = @floatFromInt(chat_win.x),
                    .y = 0,
                    .w = @floatFromInt(chat_win.w),
                    .h = @floatFromInt(tb.h),
                };
                const tb_color = gui.washColor(ui.bg, .{ .n = 7 });
                _ = sdl.render.setDrawColor(g_renderer, tb_color);
                _ = sdl.render.fillRect(g_renderer, &tb_rect);

                const btn_rect = sdl.FRect{
                    .x = @floatFromInt(chat_win.x + chat_win.w - tb.btn_w - chat_win.pad),
                    .y = @floatFromInt((tb.h - tb.btn_h) / 2),
                    .w = @floatFromInt(tb.btn_w),
                    .h = @floatFromInt(tb.btn_h),
                };
                const btn_inner = gui.washColor(ui.bg, .{ .n = 10 });
                const btn_border = gui.washColor(ui.bg, .{ .n = 14 });
                _ = gui.drawBRect(g_renderer, &btn_rect, 1.0, btn_border, btn_inner);
                renderTextCentered(g_renderer, ui.font, "Disconnect", ui.font_color, btn_rect);

                const status_rect = sdl.FRect{
                    .x = @floatFromInt(chat_win.x + chat_win.pad * 3),
                    .y = @floatFromInt((tb.h - tb.btn_h) / 2),
                    .w = @floatFromInt(tb.btn_w),
                    .h = @floatFromInt(tb.btn_h),
                };
                const status_str: [:0]const u8 = if (c.online) "Online" else "Offline";
                const status_color = if (c.online) sdl.Color{ .r = 0x50, .g = 0xc8, .b = 0x50, .a = 0xff } else sdl.Color{ .r = 0x88, .g = 0x88, .b = 0x88, .a = 0xff };
                renderTextCentered(g_renderer, ui.font, status_str, status_color, status_rect);

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

                const input_clip_rect = sdl.Rect{
                    .x = @intCast(chat_win.x),
                    .y = @intCast(chat_win.h),
                    .w = @intCast(chat_win.input_box.w),
                    .h = @intCast(chat_win.input_box.h),
                };
                _ = sdl.render.setRenderClipRect(g_renderer, &input_clip_rect);

                if (c.input.items.len > 0 or ui.mouse == .input) {
                    var in_txt = std.ArrayList(u8).empty;
                    defer in_txt.deinit(ga);
                    in_txt.appendSlice(ga, c.input.items) catch {};
                    if (c.input.items.len > 0 and c.input.items[c.input.items.len - 1] == '\n') {
                        in_txt.append(ga, ' ') catch {};
                    }
                    in_txt.append(ga, 0) catch {};

                    var tex_w: f32 = 0;
                    var tex_h: f32 = 0;

                    if (c.input.items.len > 0) {
                        const wrap_len: c_int = @as(c_int, @intCast(chat_win.input_box.w)) - 20;
                        if (sdl.ttf.renderTextBlendedWrapped(ui.font, in_txt.items[0 .. in_txt.items.len - 1 :0].ptr, in_txt.items.len - 1, ui.font_color, wrap_len)) |surf| {
                            defer sdl.surface.destroy(surf);
                            if (sdl.createTextureFromSurface(g_renderer, surf)) |tex| {
                                defer sdl.destroyTexture(tex);
                                if (sdl.getTextureSize(tex, &tex_w, &tex_h)) {
                                    var text_y_start: f32 = input_box.y + 10.0;
                                    if (tex_h < input_box.h - 20.0) {
                                        text_y_start = input_box.y + (input_box.h - tex_h) / 2.0;
                                    }
                                    const max_scroll = @max(0.0, tex_h - input_box.h + 20.0);
                                    if (ui.chat_win.input_box.scroll > max_scroll) {
                                        ui.chat_win.input_box.scroll = max_scroll;
                                    }
                                    const dst = sdl.FRect{
                                        .x = input_box.x + 10,
                                        .y = text_y_start - ui.chat_win.input_box.scroll,
                                        .w = tex_w,
                                        .h = tex_h,
                                    };
                                    _ = sdl.renderTexture(g_renderer, tex, null, &dst);
                                }
                            }
                        }
                    }

                    if (ui.mouse == .input) {
                        const current_time = sdl.getTicks();
                        if (current_time - ui.text_cursor.last_toggle > 500) {
                            ui.text_cursor.visible = !ui.text_cursor.visible;
                            ui.text_cursor.last_toggle = current_time;
                        }
                        if (ui.text_cursor.visible) {
                            var cursor_x: f32 = input_box.x + 10;
                            var cursor_y: f32 = input_box.y + (input_box.h - 20) / 2 - ui.chat_win.input_box.scroll;
                            var cursor_h: f32 = 20.0;
                            if (c.input.items.len > 0) {
                                // measure single line height
                                var sh: c_int = 0;
                                _ = sdl.ttf.getStringSize(ui.font, "A", 1, null, &sh);
                                cursor_h = @as(f32, @floatFromInt(sh));

                                // calculate X based on the last line (split by \n)
                                var last_line_start: usize = 0;
                                const raw_input = c.input.items;
                                for (raw_input, 0..) |char, i| {
                                    if (char == '\n') last_line_start = i + 1;
                                }
                                const last_line = raw_input[last_line_start..raw_input.len];
                                var cw: c_int = 0;
                                if (last_line.len > 0 and sdl.ttf.getStringSize(ui.font, @ptrCast(last_line.ptr), last_line.len, &cw, null)) {
                                    const wrap_len = @as(c_int, @intCast(chat_win.input_box.w)) - 20;
                                    var cx = @as(c_int, @intCast(cw));
                                    while (cx > wrap_len) cx -= wrap_len;
                                    cursor_x += @as(f32, @floatFromInt(cx));
                                }

                                var text_y_start: f32 = input_box.y + 10.0;
                                if (tex_h < input_box.h - 20.0) {
                                    text_y_start = input_box.y + (input_box.h - tex_h) / 2.0;
                                }
                                // Place cursor at the bottom of the text block
                                cursor_y = text_y_start - ui.chat_win.input_box.scroll + tex_h - cursor_h;
                            }
                            const cursor_rect = sdl.FRect{
                                .x = cursor_x,
                                .y = cursor_y,
                                .w = 2.0,
                                .h = cursor_h,
                            };
                            _ = sdl.render.setDrawColor(g_renderer, sdl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 });
                            _ = sdl.render.fillRect(g_renderer, &cursor_rect);
                        }
                    }
                }

                _ = sdl.render.setRenderClipRect(g_renderer, null);

                const send_bg_rect = sdl.FRect{
                    .x = @floatFromInt(chat_win.x + chat_win.input_box.w - chat_win.pad),
                    .y = input_box.y,
                    .w = @floatFromInt(2 * chat_win.pad + 2 * chat_win.send_r),
                    .h = input_box.h,
                };
                _ = sdl.render.setDrawColor(g_renderer, border_color);
                _ = sdl.render.fillRect(g_renderer, &send_bg_rect);
                const send_btn_bg = gui.washColor(ui.bg, .{ .n = 10 });
                _ = sdl.render.setDrawColor(g_renderer, send_btn_bg);
                const cx: f32 = @floatFromInt(chat_win.x + (chat_win.w + chat_win.input_box.w) / 2);
                const cy: f32 = @floatFromInt(chat_win.h + chat_win.input_box.h / 2);
                _ = gui.drawCircle(g_renderer, @intFromFloat(cx), @intFromFloat(cy), chat_win.send_r);

                const send_btn_color = sdl.FColor{ .r = 37.0 / 255.0, .g = 211.0 / 255.0, .b = 102.0 / 255.0, .a = 1.0 };
                // Offset cx slightly right for visual balance of the triangle
                _ = gui.drawRightTriangle(g_renderer, cx + 2.0, cy, @as(f32, @floatFromInt(chat_win.send_r)) * 0.9, send_btn_color);

                var msg_y: f32 = @as(f32, @floatFromInt(chat_win.h - 10)) + ui.chat_win.scroll;

                // Add clipping rect for messages
                const clip_rect = sdl.Rect{
                    .x = @intCast(chat_win.x),
                    .y = @intCast(tb.h),
                    .w = @intCast(chat_win.w),
                    .h = @intCast(chat_win.h - tb.h),
                };
                _ = sdl.render.setRenderClipRect(g_renderer, &clip_rect);

                var m_idx: usize = c.msgs.items.len;
                while (m_idx > 0) {
                    m_idx -= 1;
                    const msg = &c.msgs.items[m_idx];
                    if (msg.state == .err) continue;

                    const is_own = (msg.rid == state.rid);

                    var msg_txt = std.ArrayList(u8).empty;
                    defer msg_txt.deinit(ga);
                    msg_txt.appendSlice(ga, msg.buf) catch {};
                    msg_txt.append(ga, 0) catch {};

                    const m_color = if (msg.state == .pending) sdl.Color{ .r = 100, .g = 100, .b = 100, .a = 255 } else ui.font_color;

                    const wrap_len: c_int = @as(c_int, @intCast(chat_win.w)) - 80;
                    if (sdl.ttf.renderTextBlendedWrapped(ui.font, msg_txt.items[0 .. msg_txt.items.len - 1 :0].ptr, msg_txt.items.len - 1, m_color, wrap_len)) |surf| {
                        defer sdl.surface.destroy(surf);
                        if (sdl.createTextureFromSurface(g_renderer, surf)) |tex| {
                            defer sdl.destroyTexture(tex);
                            var w: f32, var h: f32 = .{ 0, 0 };
                            if (sdl.getTextureSize(tex, &w, &h)) {
                                msg_y -= (h + 10); // 10px spacing
                                if (msg_y > @as(f32, @floatFromInt(chat_win.h))) continue; // below view
                                if (msg_y + h < @as(f32, @floatFromInt(tb.h))) break; // out of view

                                const dst = sdl.FRect{
                                    .x = if (is_own) @as(f32, @floatFromInt(chat_win.x + chat_win.w - 20)) - w else @as(f32, @floatFromInt(chat_win.x + 20)),
                                    .y = msg_y,
                                    .w = w,
                                    .h = h,
                                };

                                // Draw bubble
                                const bubble = sdl.FRect{
                                    .x = dst.x - 5,
                                    .y = dst.y - 5,
                                    .w = dst.w + 10,
                                    .h = dst.h + 10,
                                };
                                const b_color = if (is_own) gui.washColor(ui.bg, .{ .n = 10 }) else gui.washColor(ui.bg, .{ .n = 8 });
                                _ = sdl.render.setDrawColor(g_renderer, b_color);
                                _ = sdl.render.fillRect(g_renderer, &bubble);

                                _ = sdl.renderTexture(g_renderer, tex, null, &dst);
                            }
                        }
                    }
                }

                _ = sdl.render.setRenderClipRect(g_renderer, null);

                // Clamp message scrolling
                if (ui.chat_win.scroll > 0) {
                    const top_limit = @as(f32, @floatFromInt(tb.h)) + 10.0;
                    if (msg_y > top_limit) {
                        const excess = msg_y - top_limit;
                        ui.chat_win.scroll = @max(0, ui.chat_win.scroll - excess);
                    }
                }
            }
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

fn renderTextCentered(renderer: *sdl.Renderer, font: *sdl.TtfFont, text: [:0]const u8, color: sdl.Color, rect: sdl.FRect) void {
    if (sdl.ttf.renderTextBlended(font, text, text.len, color)) |surf| {
        defer sdl.surface.destroy(surf);
        if (sdl.createTextureFromSurface(renderer, surf)) |tex| {
            defer sdl.destroyTexture(tex);
            var w: f32, var h: f32 = .{ 0, 0 };
            if (sdl.getTextureSize(tex, &w, &h)) {
                const dst = sdl.FRect{
                    .x = rect.x + (rect.w - w) / 2,
                    .y = rect.y + (rect.h - h) / 2,
                    .w = w,
                    .h = h,
                };
                _ = sdl.renderTexture(renderer, tex, null, &dst);
            }
        }
    }
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
