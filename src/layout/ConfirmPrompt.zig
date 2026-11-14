/// Centered yes/no prompt, e.g. "Close tab with 3 panes?".
///
/// The App stores what is being confirmed; this type only holds the text and
/// draws it. y / Enter confirms, n / Esc cancels.
const std = @import("std");

pub const ConfirmPrompt = struct {
    visible: bool = false,
    message_buf: [96]u8 = undefined,
    message_len: usize = 0,

    pub const hint = "[y] yes   [n] no";

    pub fn open(self: *ConfirmPrompt, text: []const u8) void {
        const n = @min(text.len, self.message_buf.len);
        @memcpy(self.message_buf[0..n], text[0..n]);
        self.message_len = n;
        self.visible = true;
    }

    pub fn close(self: *ConfirmPrompt) void {
        self.visible = false;
    }

    pub fn message(self: *const ConfirmPrompt) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    pub const Metrics = struct { x: i32, y: i32, w: u32, h: u32, col_width: u32, row_height: u32 };

    pub fn computeMetrics(message_len: usize, cell_width: f32, cell_height: f32, window_width: u32, window_height: u32) Metrics {
        const cw: u32 = @intFromFloat(@max(1.0, cell_width));
        const ch: u32 = @intFromFloat(@max(1.0, cell_height));
        const cols: u32 = @intCast(@max(message_len, hint.len) + 4);
        const w = @min(cols * cw, window_width);
        const h = 4 * ch;
        return .{
            .x = @intCast((window_width -| w) / 2),
            .y = @intCast((window_height -| h) / 2),
            .w = w,
            .h = h,
            .col_width = cw,
            .row_height = ch,
        };
    }

    pub fn render(
        self: *const ConfirmPrompt,
        cell_width: f32,
        cell_height: f32,
        window_width: u32,
        window_height: u32,
        colors: Colors,
        draw_rect_fn: *const fn (x: i32, y: i32, w: u32, h: u32, color: u32, ctx: *anyopaque) void,
        draw_text_fn: *const fn (text: []const u8, x: i32, y: i32, color: u32, ctx: *anyopaque) void,
        ctx: *anyopaque,
    ) void {
        if (!self.visible) return;
        const msg = self.message();
        const m = computeMetrics(msg.len, cell_width, cell_height, window_width, window_height);

        // Alpha 0 = the caller draws its own (blended) backdrop.
        if (colors.overlay_bg & 0xFF != 0) draw_rect_fn(0, 0, window_width, window_height, colors.overlay_bg, ctx);
        draw_rect_fn(m.x, m.y, m.w, m.h, colors.bg, ctx);
        draw_rect_fn(m.x, m.y, m.w, 1, colors.border, ctx);
        draw_rect_fn(m.x, m.y + @as(i32, @intCast(m.h)) - 1, m.w, 1, colors.border, ctx);
        draw_rect_fn(m.x, m.y, 1, m.h, colors.border, ctx);
        draw_rect_fn(m.x + @as(i32, @intCast(m.w)) - 1, m.y, 1, m.h, colors.border, ctx);

        const text_x = m.x + @as(i32, @intCast(m.col_width * 2));
        draw_text_fn(msg, text_x, m.y + @as(i32, @intCast(m.row_height)), colors.fg, ctx);
        draw_text_fn(hint, text_x, m.y + @as(i32, @intCast(m.row_height * 2)), colors.hint, ctx);
    }
};

pub const Colors = struct {
    bg: u32,
    border: u32,
    fg: u32,
    hint: u32,
    /// Full-window backdrop; alpha 0 skips it.
    overlay_bg: u32,
};

test "ConfirmPrompt: open stores the message, close hides it" {
    var p = ConfirmPrompt{};
    try std.testing.expect(!p.visible);
    p.open("Close tab with 3 panes?");
    try std.testing.expect(p.visible);
    try std.testing.expectEqualStrings("Close tab with 3 panes?", p.message());
    p.close();
    try std.testing.expect(!p.visible);
}

test "ConfirmPrompt: metrics are centered and fit the longer line" {
    const m = ConfirmPrompt.computeMetrics(23, 8.0, 17.0, 800, 600);
    try std.testing.expectEqual(@as(u32, (23 + 4) * 8), m.w);
    try std.testing.expectEqual(@as(u32, 4 * 17), m.h);
    try std.testing.expectEqual(@as(i32, (800 - 216) / 2), m.x);
}
