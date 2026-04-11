/// GPU-rendered title bar and tab bar.
///
/// Two-row layout:
///   Row 1 (Title bar): icon centered, window controls right (colored dots)
///   Row 2 (Tab bar): tabs with close buttons, "+" new tab button
///
/// Window controls styled as colored dots: yellow minimize, green maximize, red close.
const std = @import("std");
const layout = @import("layout.zig");
const TabManager = layout.TabManager.TabManager;
const Rect = layout.Rect.Rect;
const Compositor = @import("Compositor.zig");
const ColorU32 = Compositor.ColorU32;

pub const TabBarConfig = struct {
    tab_bar_bg: ColorU32,
    tab_active: ColorU32,
    tab_inactive: ColorU32,
    fg_color: ColorU32,
    agent_alert: ColorU32,
    pane_border: ColorU32,

    cell_width: f32,
    cell_height: f32,

    tab_pad_h: u32 = 8,
    tab_pad_v: u32 = 4,

    /// Text scale factor for tab labels (0.75 = 75% of normal font size)
    text_scale: f32 = 0.75,

    /// Hovered control button (0=none, 1=minimize, 2=maximize, 3=close)
    hovered_control: u8 = 0,
};

// Control button colors
const color_close: ColorU32 = 0xFF5F57FF; // red
const color_maximize: ColorU32 = 0x28C840FF; // green
const color_minimize: ColorU32 = 0xFEBC2EFF; // yellow

pub const TabBarRenderer = struct {

    // ── Dimensions ───────────────────────────────────────

    pub fn titleBarHeight(cell_height: f32) u32 {
        return @as(u32, @intFromFloat(cell_height)) + 8;
    }

    pub fn tabBarHeight(cell_height: f32, tab_pad_v: u32) u32 {
        _ = tab_pad_v;
        return titleBarHeight(cell_height); // Same as title bar
    }

    pub fn computeHeight(cell_height: f32, tab_pad_v: u32) u32 {
        return titleBarHeight(cell_height) + tabBarHeight(cell_height, tab_pad_v);
    }

    /// Width of each control button (square, matching title bar height).
    pub fn controlBtnWidth(cell_height: f32) u32 {
        return titleBarHeight(cell_height);
    }

    /// Total width of all three control buttons.
    pub fn controlsTotalWidth(cell_height: f32) u32 {
        return controlBtnWidth(cell_height) * 3;
    }

    // ── Rendering ────────────────────────────────────────

    pub fn render(
        tab_manager: *const TabManager,
        config: TabBarConfig,
        window_width: u32,
        _total_height: u32,
        draw_rect_fn: *const fn (rect: Rect, color: ColorU32, ctx: *anyopaque) void,
        draw_text_fn: *const fn (text: []const u8, x: i32, y: i32, color: ColorU32, ctx: *anyopaque) void,
        draw_icon_fn: ?*const fn (x: i32, y: i32, size: u32, ctx: *anyopaque) void,
        draw_ctx: *anyopaque,
    ) void {
        _ = _total_height;
        const title_h = titleBarHeight(config.cell_height);
        const tab_h = tabBarHeight(config.cell_height, config.tab_pad_v);
        const ww: i32 = @intCast(window_width);
        const title_h_i: i32 = @intCast(title_h);

        // ── Title bar background ─────────────────────────
        draw_rect_fn(.{ .x = 0, .y = 0, .w = window_width, .h = title_h }, config.tab_bar_bg, draw_ctx);

        // 1px separator
        draw_rect_fn(.{ .x = 0, .y = title_h_i - 1, .w = window_width, .h = 1 }, config.pane_border, draw_ctx);

        // ── Logo: icon centered ──────────────────────────
        const icon_display: u32 = if (title_h > 6) title_h - 6 else title_h;
        const icon_y: i32 = @divFloor(title_h_i - @as(i32, @intCast(icon_display)), 2) + 1;
        const icon_x: i32 = @divFloor(ww - @as(i32, @intCast(icon_display)), 2);
        if (draw_icon_fn) |icon_fn| {
            icon_fn(icon_x, icon_y, icon_display, draw_ctx);
        }

        // ── Window controls: colored geometric shapes ─────
        const btn_w: u32 = controlBtnWidth(config.cell_height);
        const btn_w_i: i32 = @intCast(btn_w);
        const icon_sz: u32 = @intFromFloat(config.cell_height * 0.4);
        const cy: i32 = @divFloor(title_h_i, 2);
        const half: i32 = @intCast(icon_sz / 2);

        // Lighten just the hovered control's background slightly
        const hover_bg: ColorU32 = (config.tab_bar_bg & 0xFFFFFF00) | 0xFF;
        // Compute a slightly brighter version of the title bar bg
        const bg_r = @as(u8, @truncate((config.tab_bar_bg >> 24) & 0xFF));
        const bg_g = @as(u8, @truncate((config.tab_bar_bg >> 16) & 0xFF));
        const bg_b = @as(u8, @truncate((config.tab_bar_bg >> 8) & 0xFF));
        const bump: u8 = 15; // small brightness bump
        const hover_color: ColorU32 = (@as(u32, @min(255, @as(u16, bg_r) + bump)) << 24) |
            (@as(u32, @min(255, @as(u16, bg_g) + bump)) << 16) |
            (@as(u32, @min(255, @as(u16, bg_b) + bump)) << 8) | 0xFF;
        _ = hover_bg;

        // Close (rightmost) — red X
        {
            const bx = ww - btn_w_i;
            if (config.hovered_control == 3) {
                draw_rect_fn(.{ .x = bx, .y = 0, .w = btn_w, .h = title_h - 1 }, hover_color, draw_ctx);
            }
            const cx = bx + @divFloor(btn_w_i, 2);
            var i: i32 = -half;
            while (i <= half) : (i += 1) {
                draw_rect_fn(.{ .x = cx + i, .y = cy + i, .w = 2, .h = 2 }, color_close, draw_ctx);
                draw_rect_fn(.{ .x = cx - i, .y = cy + i, .w = 2, .h = 2 }, color_close, draw_ctx);
            }
        }

        // Maximize (middle) — green square outline
        {
            const bx = ww - btn_w_i * 2;
            if (config.hovered_control == 2) {
                draw_rect_fn(.{ .x = bx, .y = 0, .w = btn_w, .h = title_h - 1 }, hover_color, draw_ctx);
            }
            const cx = bx + @divFloor(btn_w_i, 2);
            draw_rect_fn(.{ .x = cx - half, .y = cy - half, .w = icon_sz, .h = 2 }, color_maximize, draw_ctx);
            draw_rect_fn(.{ .x = cx - half, .y = cy + half - 2, .w = icon_sz, .h = 2 }, color_maximize, draw_ctx);
            draw_rect_fn(.{ .x = cx - half, .y = cy - half, .w = 2, .h = icon_sz }, color_maximize, draw_ctx);
            draw_rect_fn(.{ .x = cx + half - 2, .y = cy - half, .w = 2, .h = icon_sz }, color_maximize, draw_ctx);
        }

        // Minimize (leftmost of three) — yellow horizontal line
        {
            const bx = ww - btn_w_i * 3;
            if (config.hovered_control == 1) {
                draw_rect_fn(.{ .x = bx, .y = 0, .w = btn_w, .h = title_h - 1 }, hover_color, draw_ctx);
            }
            const cx = bx + @divFloor(btn_w_i, 2);
            draw_rect_fn(.{ .x = cx - half, .y = cy, .w = icon_sz, .h = 2 }, color_minimize, draw_ctx);
        }

        // ── Tab bar background ───────────────────────────
        const tab_y: i32 = title_h_i;
        draw_rect_fn(.{ .x = 0, .y = tab_y, .w = window_width, .h = tab_h }, config.tab_bar_bg, draw_ctx);

        // 1px separator under tab bar (lighter than title bar separator)
        {
            const sep_r = @as(u8, @truncate((config.pane_border >> 24) & 0xFF));
            const sep_g = @as(u8, @truncate((config.pane_border >> 16) & 0xFF));
            const sep_b = @as(u8, @truncate((config.pane_border >> 8) & 0xFF));
            const lighter: ColorU32 = (@as(u32, @min(255, @as(u16, sep_r) + 30)) << 24) |
                (@as(u32, @min(255, @as(u16, sep_g) + 30)) << 16) |
                (@as(u32, @min(255, @as(u16, sep_b) + 30)) << 8) | 0xFF;
            draw_rect_fn(.{ .x = 0, .y = tab_y + @as(i32, @intCast(tab_h)) - 1, .w = window_width, .h = 1 }, lighter, draw_ctx);
        }

        const tab_count = tab_manager.tabCount();
        if (tab_count == 0) return;

        // ── Compute tab widths ───────────────────────────
        // Tabs fill available space equally, no max cap — only shrink when crowded
        const new_tab_button_w: u32 = @intFromFloat(config.cell_width * 3.0);
        const available_w: u32 = if (window_width > new_tab_button_w) window_width - new_tab_button_w else window_width;
        const tab_w: u32 = if (tab_count > 0) available_w / @as(u32, @intCast(tab_count)) else available_w;

        // Vertically center scaled text in tab bar
        const scaled_h: i32 = @intFromFloat(config.cell_height * config.text_scale);
        const text_y: i32 = tab_y + @divFloor(@as(i32, @intCast(tab_h)) - scaled_h, 2);
        const cell_w_int: i32 = @intFromFloat(config.cell_width * config.text_scale);

        // ── Render each tab ──────────────────────────────
        for (tab_manager.tabs.items, 0..) |tab, idx| {
            const tab_x: i32 = @intCast(@as(u32, @intCast(idx)) * tab_w);
            const is_active = idx == tab_manager.active_idx;

            const tab_bg_color = if (is_active) config.tab_active else config.tab_inactive;
            draw_rect_fn(.{ .x = tab_x, .y = tab_y, .w = tab_w, .h = tab_h }, tab_bg_color, draw_ctx);

            // Active tab accent line
            if (is_active) {
                draw_rect_fn(.{
                    .x = tab_x,
                    .y = tab_y + @as(i32, @intCast(tab_h)) - 2,
                    .w = tab_w,
                    .h = 2,
                }, config.pane_border, draw_ctx);
            }

            // Always reserve space for activity indicator so title doesn't shift
            var text_x: i32 = tab_x + @as(i32, @intCast(config.tab_pad_h));
            const indicator_x = text_x;
            text_x += cell_w_int; // reserved slot

            if (tab.has_activity and !is_active) {
                // Yellow diamond — vertically centered in reserved slot
                const star_cx = indicator_x + @divFloor(cell_w_int, 2);
                const star_cy = tab_y + @divFloor(@as(i32, @intCast(tab_h)), 2);
                const star_r: i32 = @intFromFloat(config.cell_height * 0.12);
                var si: i32 = -star_r;
                while (si <= star_r) : (si += 1) {
                    const span = star_r - @as(i32, if (si < 0) -si else si);
                    draw_rect_fn(.{ .x = star_cx - span, .y = star_cy + si, .w = @intCast(@as(u32, @intCast(span * 2 + 1))), .h = 1 }, color_minimize, draw_ctx);
                }
            }

            // Tab label: "N: title" or just "N" if no title
            var num_buf: [4]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{idx + 1}) catch "?";
            draw_text_fn(num_str, text_x, text_y, config.fg_color, draw_ctx);
            text_x += cell_w_int * @as(i32, @intCast(num_str.len));

            const title_text = tab.title[0..tab.title_len];
            if (title_text.len > 0) {
                draw_text_fn(":", text_x, text_y, config.fg_color, draw_ctx);
                text_x += cell_w_int;

                const close_button_w = cell_w_int * 2;
                const max_title_px = @as(i32, @intCast(tab_w)) - (text_x - tab_x) - close_button_w;
                const max_title_chars: usize = if (max_title_px > 0) @intCast(@divFloor(max_title_px, cell_w_int)) else 0;

                const display_len = @min(title_text.len, max_title_chars);
                if (display_len > 0) {
                    draw_text_fn(title_text[0..display_len], text_x, text_y, config.fg_color, draw_ctx);
                }
            }

            // Tab close button — red geometric X, vertically centered
            {
                const close_cx = tab_x + @as(i32, @intCast(tab_w)) - cell_w_int;
                const close_cy = tab_y + @divFloor(@as(i32, @intCast(tab_h)), 2);
                const close_arm: u32 = @intFromFloat(config.cell_height * 0.15);
                const close_arm_i: i32 = @intCast(close_arm);
                var ci: i32 = -close_arm_i;
                while (ci <= close_arm_i) : (ci += 1) {
                    draw_rect_fn(.{ .x = close_cx + ci, .y = close_cy + ci, .w = 2, .h = 2 }, color_close, draw_ctx);
                    draw_rect_fn(.{ .x = close_cx - ci, .y = close_cy + ci, .w = 2, .h = 2 }, color_close, draw_ctx);
                }
            }
        }

        // "+" new tab button — blue geometric plus
        {
            const color_plus: ColorU32 = 0x5899F0FF; // soft blue
            const plus_btn_x: i32 = @intCast(@as(u32, @intCast(tab_count)) * tab_w);
            const plus_cx = plus_btn_x + @divFloor(@as(i32, @intCast(new_tab_button_w)), 2);
            const plus_cy = tab_y + @divFloor(@as(i32, @intCast(tab_h)), 2);
            const arm: u32 = @intFromFloat(config.cell_height * 0.25);
            const arm_i: i32 = @intCast(arm);
            // Horizontal bar
            draw_rect_fn(.{ .x = plus_cx - arm_i, .y = plus_cy - 1, .w = arm * 2 + 2, .h = 2 }, color_plus, draw_ctx);
            // Vertical bar
            draw_rect_fn(.{ .x = plus_cx, .y = plus_cy - arm_i, .w = 2, .h = arm * 2 + 2 }, color_plus, draw_ctx);
        }
    }

    // ── Hit testing ──────────────────────────────────────
    // All coordinates are in the SAME space as the render (framebuffer pixels).

    pub const HitResult = union(enum) {
        tab: usize,
        close_tab: usize,
        new_tab: void,
        window_minimize: void,
        window_maximize: void,
        window_close: void,
        drag_region: void,
        none: void,
    };

    pub fn hitTest(
        x: i32,
        y: i32,
        tab_count: usize,
        cell_width: f32,
        cell_height: f32,
        window_width: u32,
    ) HitResult {
        const title_h: i32 = @intCast(titleBarHeight(cell_height));
        const total_h: i32 = @intCast(computeHeight(cell_height, 4));
        const ww: i32 = @intCast(window_width);
        const btn_w: i32 = @intCast(controlBtnWidth(cell_height));

        // ── Title bar region ─────────────────────────────
        if (y < title_h) {
            if (x >= ww - btn_w) return .{ .window_close = {} };
            if (x >= ww - btn_w * 2) return .{ .window_maximize = {} };
            if (x >= ww - btn_w * 3) return .{ .window_minimize = {} };
            return .{ .drag_region = {} };
        }

        // ── Tab bar region ───────────────────────────────
        if (y >= total_h) return .{ .none = {} };

        if (tab_count == 0) return .{ .drag_region = {} };

        const new_tab_button_w: u32 = @intFromFloat(cell_width * 3.0);
        const available_w: u32 = if (window_width > new_tab_button_w) window_width - new_tab_button_w else window_width;
        const tab_w: u32 = if (tab_count > 0) available_w / @as(u32, @intCast(tab_count)) else available_w;
        const total_tabs_w: i32 = @intCast(@as(u32, @intCast(tab_count)) * tab_w);
        const cell_w_int: i32 = @intFromFloat(cell_width);

        if (x >= total_tabs_w and x < total_tabs_w + @as(i32, @intCast(new_tab_button_w))) {
            return .{ .new_tab = {} };
        }

        if (x >= 0 and x < total_tabs_w) {
            const tab_idx: usize = @intCast(@divFloor(x, @as(i32, @intCast(tab_w))));
            if (tab_idx < tab_count) {
                const tab_right: i32 = @intCast(@as(u32, @intCast(tab_idx + 1)) * tab_w);
                if (x >= tab_right - cell_w_int * 2) {
                    return .{ .close_tab = tab_idx };
                }
                return .{ .tab = tab_idx };
            }
        }

        return .{ .drag_region = {} };
    }

    /// Check if a point (framebuffer coords) is in the controls area.
    pub fn isInControlsArea(x: i32, y: i32, cell_height: f32, window_width: u32) bool {
        const title_h: i32 = @intCast(titleBarHeight(cell_height));
        const btn_w: i32 = @intCast(controlBtnWidth(cell_height));
        const ww: i32 = @intCast(window_width);
        return y < title_h and x >= ww - btn_w * 3;
    }
};

// ── Tests ────────────────────────────────────────────────

test "TabBarRenderer.computeHeight" {
    const height = TabBarRenderer.computeHeight(17.0, 4);
    try std.testing.expectEqual(@as(u32, 50), height); // 25 + 25
}

test "TabBarRenderer.hitTest title drag" {
    const result = TabBarRenderer.hitTest(50, 5, 3, 8.0, 17.0, 800);
    switch (result) {
        .drag_region => {},
        else => return error.TestUnexpectedResult,
    }
}

test "TabBarRenderer.hitTest window close" {
    // btn_w = titleBarHeight(17) = 25, close at 800-25=775+
    const result = TabBarRenderer.hitTest(780, 5, 1, 8.0, 17.0, 800);
    switch (result) {
        .window_close => {},
        else => return error.TestUnexpectedResult,
    }
}

test "TabBarRenderer.hitTest tab region" {
    // title_h = 25, tab bar starts at y=25
    const result = TabBarRenderer.hitTest(50, 30, 3, 8.0, 17.0, 800);
    switch (result) {
        .tab => {},
        else => return error.TestUnexpectedResult,
    }
}
