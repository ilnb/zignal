pub const UI = struct {
    pub const UserBox = struct {
        w: usize,
        h: usize,
        pad: usize = 2,
        scroll: f32 = 0,
        font_size: f32 = 15.0,
    };
    pub const ChatWin = struct {
        pub const InputBox = struct {
            w: usize = undefined,
            h: usize = 60,
            scroll: f32 = 0,
        };
        pub const TopBar = struct {
            h: usize = 40,
            btn_w: usize = 120,
            btn_h: usize = 24,
        };

        w: usize = undefined,
        h: usize = undefined,
        x: usize = undefined,
        input_box: InputBox = .{},
        top_bar: TopBar = .{},
        pad: usize = 3,
        scroll: f32 = 0,
        send_r: usize = 20,
        font_size: f32 = 10.0,
        bg: sdl.Color = undefined,
        font_color: sdl.Color = undefined,
    };
    pub const MouseState = enum {
        on_list,
        on_chat,
        input,
        to_link,
    };
    pub const Cursor = struct {
        x: f32 = 0,
        y: f32 = 0,
    };

    w: usize,
    h: usize,
    sep_width: usize = 1,
    curr_user: ?usize = null,
    user_box: UserBox,
    chat_win: ChatWin = .{},
    mouse: MouseState = .on_list,
    cursor: Cursor = .{},
    text_cursor: struct {
        visible: bool = true,
        last_toggle: u64 = 0,
    } = .{},
    font: *sdl.TtfFont = undefined,
    bg: sdl.Color = undefined,
    font_color: sdl.Color = undefined,
    sep_color: sdl.Color = undefined,
};

pub inline fn drawCircle(r: *sdl.Renderer, cx: i32, cy: i32, radius: usize) bool {
    var x: i32, var y: i32 = .{ 0, @intCast(radius) };
    var d: i32 = 3 - 2 * y;
    var ret = true;
    while (y >= x) : (x += 1) {
        ret &= sdl.render.line(r, @floatFromInt(cx - x), @floatFromInt(cy - y), @floatFromInt(cx + x), @floatFromInt(cy - y));
        ret &= sdl.render.line(r, @floatFromInt(cx - x), @floatFromInt(cy + y), @floatFromInt(cx + x), @floatFromInt(cy + y));
        ret &= sdl.render.line(r, @floatFromInt(cx - y), @floatFromInt(cy - x), @floatFromInt(cx + y), @floatFromInt(cy - x));
        ret &= sdl.render.line(r, @floatFromInt(cx - y), @floatFromInt(cy + x), @floatFromInt(cx + y), @floatFromInt(cy + x));
        if (d < 0) {
            d += 4 * x + 6;
        } else {
            d += 4 * (x - y) + 10;
            y -= 1;
        }
    }
    return ret;
}

pub inline fn drawRightTriangle(r: *sdl.Renderer, cx: f32, cy: f32, size: f32, color: sdl.FColor) bool {
    const vertices = [_]sdl.Vertex{
        .{ .position = .{ .x = cx - size / 2.0, .y = cy - size / 2.0 }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } },
        .{ .position = .{ .x = cx - size / 2.0, .y = cy + size / 2.0 }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } },
        .{ .position = .{ .x = cx + size / 2.0, .y = cy }, .color = color, .tex_coord = .{ .x = 0, .y = 0 } },
    };
    return sdl.renderGeometry(r, null, &vertices, 3, null, 0);
}

pub const WashRatio = struct {
    n: u32 = 5,
    d: ?u32 = null,
};

pub inline fn drawBRect(r: *sdl.Renderer, rect: *const sdl.FRect, pad: f32, border_color: sdl.Color, inner_color: sdl.Color) bool {
    const inner_rect: sdl.FRect = .{
        .x = rect.x + pad,
        .y = rect.y + pad,
        .w = rect.w - 2 * pad,
        .h = rect.h - 2 * pad,
    };

    var ret: bool = true;
    ret &= sdl.render.setDrawColor(r, border_color);
    ret &= sdl.render.fillRect(r, rect);
    ret &= sdl.render.setDrawColor(r, inner_color);
    ret &= sdl.render.fillRect(r, &inner_rect);
    return ret;
}

pub inline fn washColor(color: sdl.Color, ratio: WashRatio) sdl.Color {
    const n = ratio.n;
    const d = ratio.d orelse (n + 1);
    var white_washed: sdl.Color = undefined;
    inline for (@typeInfo(sdl.Color).@"struct".fields) |f| {
        const washed_color = (@as(u32, @intCast(@field(color, f.name))) * n + 0xff) / d;
        @field(white_washed, f.name) = @intCast(washed_color);
    }
    return white_washed;
}

pub inline fn rectToFRect(rect: sdl.Rect) sdl.FRect {
    var ret: sdl.FRect = undefined;
    inline for (@typeInfo(sdl.Rect).@"struct".fields) |f| {
        @field(ret, f.name) = @floatFromInt(@field(rect, f.name));
    }
    return ret;
}

pub inline fn modColor(color: anytype, gain: f32) @TypeOf(color) {
    const T = @TypeOf(color);
    const type_info = @typeInfo(T).@"struct";
    var ret: T = undefined;
    inline for (type_info.fields) |f| {
        const val = @field(color, f.name);
        if (comptime @typeInfo(f.type) == .float) {
            @field(ret, f.name) = std.math.clamp((1.0 + gain) * val, 0.0, 1.0);
        } else {
            const scaled = (1.0 + gain) * @as(f32, @floatFromInt(val));
            @field(ret, f.name) = @intFromFloat(std.math.clamp(scaled, 0.0, 255.0));
        }
    }
    ret.a = color.a;
    return ret;
}

const std = @import("std");
const sdl = @import("zsdl3");
const types = @import("types");
