/// GPU-rendered status bar showing per-pane agent state.
///
/// Displays at the window bottom with per-pane segments showing [N:state]
/// for the current tab, plus a background-tab waiting summary.
///
/// Uses callback-based rendering (same pattern as TabBarRenderer) so it
/// can be tested without a GPU context.
const std = @import("std");
const AgentState = @import("agent_state").AgentState;

/// Color type alias matching Compositor.ColorU32.
pub const ColorU32 = u32;

/// Agent state enum, re-exported from AgentState for convenience.
pub const AgentStateEnum = AgentState.State;

/// Per-pane status info, ordered by visual position (left-to-right, top-to-bottom).
pub const PaneStatusInfo = struct {
    pane_number: u32,
    state: AgentStateEnum,
    is_focused: bool,
};

/// Configuration for status bar colors (all parameterized for theme support).
pub const StatusBarConfig = struct {
    bg_color: ColorU32, // status_bar_bg
    border_color: ColorU32, // pane_border (top separator line)
    idle_color: ColorU32, // dim: status_bar_bg lightened 30%
    working_color: ColorU32, // theme green (ANSI color 2)
    waiting_color: ColorU32, // agent_alert
    focused_bg_color: ColorU32, // status_bar_bg lightened 15%
};

pub const StatusBarRenderer = struct {

    // ── Dimensions ───────────────────────────────────────

    /// Status bar height: cell_height + 8px (matches TabBarRenderer.titleBarHeight).
    pub fn statusBarHeight(cell_height: f32) u32 {
        return @as(u32, @intFromFloat(cell_height)) + 8;
    }

    // ── Rendering ────────────────────────────────────────

    pub fn render(
        pane_states: []const PaneStatusInfo,
        config: StatusBarConfig,
        window_width: u32,
        y_offset: u32,
        cell_height: f32,
        background_waiting_count: u32,
        draw_rect_fn: *const fn (x: i32, y: i32, w: u32, h: u32, color: ColorU32, ctx: *anyopaque) void,
        draw_text_fn: *const fn (text: []const u8, x: i32, y: i32, color: ColorU32, scale: f32, ctx: *anyopaque) void,
        draw_ctx: *anyopaque,
    ) void {
        const height = statusBarHeight(cell_height);
        const y: i32 = @intCast(y_offset);

        // 1. Full-width background rect
        draw_rect_fn(0, y, window_width, height, config.bg_color, draw_ctx);

        // 2. 1px top border
        draw_rect_fn(0, y, window_width, 1, config.border_color, draw_ctx);

        // 3. Per-pane segments
        const text_scale: f32 = 0.75;
        const text_y: i32 = y + 4;
        var x_cursor: i32 = 8; // left padding

        for (pane_states) |pane| {
            var buf: [32]u8 = undefined;
            const segment = formatSegment(&buf, pane.pane_number, pane.state);
            const text_width = estimateTextWidth(segment.len, cell_height);

            // Focused pane gets highlighted background behind segment
            if (pane.is_focused) {
                const pad: u32 = 4;
                draw_rect_fn(
                    x_cursor - @as(i32, @intCast(pad / 2)),
                    y + 2,
                    text_width + pad,
                    height - 4,
                    config.focused_bg_color,
                    draw_ctx,
                );
            }

            // Choose color by state
            const color: ColorU32 = switch (pane.state) {
                .idle => config.idle_color,
                .working => config.working_color,
                .waiting => config.waiting_color,
            };

            draw_text_fn(segment, x_cursor, text_y, color, text_scale, draw_ctx);
            x_cursor += @as(i32, @intCast(text_width)) + 8; // 8px gap
        }

        // 4. Background tab waiting summary (right-aligned)
        if (background_waiting_count > 0) {
            var summary_buf: [32]u8 = undefined;
            const summary = formatSummary(&summary_buf, background_waiting_count);
            const summary_width = estimateTextWidth(summary.len, cell_height);
            const summary_x: i32 = @as(i32, @intCast(window_width)) - @as(i32, @intCast(summary_width)) - 8;
            draw_text_fn(summary, summary_x, text_y, config.waiting_color, text_scale, draw_ctx);
        }
    }

    // ── Hit testing ───────────────────────────────────────

    /// Hit test a click in the status bar area.
    /// Returns the pane_number of the clicked segment, or null if no segment hit.
    pub fn hitTest(
        pane_states: []const PaneStatusInfo,
        click_x: i32,
        cell_height: f32,
    ) ?u32 {
        var x_cursor: i32 = 8; // same left padding as render

        for (pane_states) |pane| {
            var buf: [32]u8 = undefined;
            const segment = formatSegment(&buf, pane.pane_number, pane.state);
            const text_width = estimateTextWidth(segment.len, cell_height);
            const seg_end = x_cursor + @as(i32, @intCast(text_width));

            if (click_x >= x_cursor - 2 and click_x < seg_end + 4) {
                return pane.pane_number;
            }
            x_cursor = seg_end + 8; // 8px gap
        }
        return null;
    }

    // ── Internal helpers ─────────────────────────────────

    /// Format a segment label: "[{pane_number}:{state}]"
    pub fn formatSegment(buf: []u8, pane_number: u32, state: AgentStateEnum) []const u8 {
        return std.fmt.bufPrint(buf, "[{d}:{s}]", .{ pane_number, state.str() }) catch "???";
    }

    /// Format summary text: "{N} waiting"
    fn formatSummary(buf: []u8, count: u32) []const u8 {
        return std.fmt.bufPrint(buf, "{d} waiting", .{count}) catch "? waiting";
    }

    /// Estimate pixel width of text at 0.75 scale.
    /// Approximate character width = cell_height * 0.75 * 0.6
    pub fn estimateTextWidth(text_len: usize, cell_height: f32) u32 {
        const char_width = cell_height * 0.75 * 0.6;
        return @as(u32, @intFromFloat(@as(f32, @floatFromInt(text_len)) * char_width));
    }
};

// ── Test infrastructure ─────────────────────────────────

const DrawRectCall = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    color: ColorU32,
};

const DrawTextCall = struct {
    text: [64]u8,
    text_len: usize,
    x: i32,
    y: i32,
    color: ColorU32,
    scale: f32,

    fn getText(self: *const DrawTextCall) []const u8 {
        return self.text[0..self.text_len];
    }
};

const TestContext = struct {
    rect_calls: [32]DrawRectCall = undefined,
    rect_count: usize = 0,
    text_calls: [16]DrawTextCall = undefined,
    text_count: usize = 0,

    fn recordRect(ctx: *TestContext, x: i32, y: i32, w: u32, h: u32, color: ColorU32) void {
        if (ctx.rect_count < 32) {
            ctx.rect_calls[ctx.rect_count] = .{ .x = x, .y = y, .w = w, .h = h, .color = color };
            ctx.rect_count += 1;
        }
    }

    fn recordText(ctx: *TestContext, text: []const u8, x: i32, y: i32, color: ColorU32, scale: f32) void {
        if (ctx.text_count < 16) {
            var entry: DrawTextCall = .{
                .text = undefined,
                .text_len = @min(text.len, 64),
                .x = x,
                .y = y,
                .color = color,
                .scale = scale,
            };
            @memcpy(entry.text[0..entry.text_len], text[0..entry.text_len]);
            ctx.text_calls[ctx.text_count] = entry;
            ctx.text_count += 1;
        }
    }
};

fn testDrawRect(x: i32, y: i32, w: u32, h: u32, color: ColorU32, ctx: *anyopaque) void {
    const tc: *TestContext = @ptrCast(@alignCast(ctx));
    tc.recordRect(x, y, w, h, color);
}

fn testDrawText(text: []const u8, x: i32, y: i32, color: ColorU32, scale: f32, ctx: *anyopaque) void {
    const tc: *TestContext = @ptrCast(@alignCast(ctx));
    tc.recordText(text, x, y, color, scale);
}

const test_config = StatusBarConfig{
    .bg_color = 0x1E1E2EFF,
    .border_color = 0x45475AFF,
    .idle_color = 0x6C7086FF,
    .working_color = 0xA6E3A1FF,
    .waiting_color = 0xFAB387FF,
    .focused_bg_color = 0x313244FF,
};

// ── Tests ───────────────────────────────────────────────

test "statusBarHeight returns cell_height + 8" {
    try std.testing.expectEqual(@as(u32, 25), StatusBarRenderer.statusBarHeight(17.0));
    try std.testing.expectEqual(@as(u32, 24), StatusBarRenderer.statusBarHeight(16.0));
    try std.testing.expectEqual(@as(u32, 28), StatusBarRenderer.statusBarHeight(20.0));
}

test "formatSegment idle" {
    var buf: [32]u8 = undefined;
    const result = StatusBarRenderer.formatSegment(&buf, 1, .idle);
    try std.testing.expectEqualStrings("[1:idle]", result);
}

test "formatSegment working" {
    var buf: [32]u8 = undefined;
    const result = StatusBarRenderer.formatSegment(&buf, 2, .working);
    try std.testing.expectEqualStrings("[2:working]", result);
}

test "formatSegment waiting" {
    var buf: [32]u8 = undefined;
    const result = StatusBarRenderer.formatSegment(&buf, 3, .waiting);
    try std.testing.expectEqualStrings("[3:waiting]", result);
}

test "estimateTextWidth basic" {
    // 8 chars * 17 * 0.75 * 0.6 = 8 * 7.65 = 61.2 -> 61
    const width = StatusBarRenderer.estimateTextWidth(8, 17.0);
    try std.testing.expectEqual(@as(u32, 61), width);
}

test "render empty pane_states draws only background and border" {
    var ctx = TestContext{};
    const panes = [_]PaneStatusInfo{};

    StatusBarRenderer.render(
        &panes,
        test_config,
        800,
        575,
        17.0,
        0,
        &testDrawRect,
        &testDrawText,
        @ptrCast(&ctx),
    );

    // Background + border = 2 rects
    try std.testing.expectEqual(@as(usize, 2), ctx.rect_count);
    // No text
    try std.testing.expectEqual(@as(usize, 0), ctx.text_count);

    // Background rect
    try std.testing.expectEqual(@as(i32, 0), ctx.rect_calls[0].x);
    try std.testing.expectEqual(@as(i32, 575), ctx.rect_calls[0].y);
    try std.testing.expectEqual(@as(u32, 800), ctx.rect_calls[0].w);
    try std.testing.expectEqual(test_config.bg_color, ctx.rect_calls[0].color);

    // Border rect
    try std.testing.expectEqual(@as(u32, 1), ctx.rect_calls[1].h);
    try std.testing.expectEqual(test_config.border_color, ctx.rect_calls[1].color);
}

test "render single focused idle pane" {
    var ctx = TestContext{};
    const panes = [_]PaneStatusInfo{
        .{ .pane_number = 1, .state = .idle, .is_focused = true },
    };

    StatusBarRenderer.render(
        &panes,
        test_config,
        800,
        575,
        17.0,
        0,
        &testDrawRect,
        &testDrawText,
        @ptrCast(&ctx),
    );

    // Background + border + focused highlight = 3 rects
    try std.testing.expectEqual(@as(usize, 3), ctx.rect_count);
    // 1 text call for segment
    try std.testing.expectEqual(@as(usize, 1), ctx.text_count);

    // Text is "[1:idle]" in idle_color
    try std.testing.expectEqualStrings("[1:idle]", ctx.text_calls[0].getText());
    try std.testing.expectEqual(test_config.idle_color, ctx.text_calls[0].color);

    // Focused highlight rect uses focused_bg_color
    try std.testing.expectEqual(test_config.focused_bg_color, ctx.rect_calls[2].color);
}

test "render two panes with correct colors" {
    var ctx = TestContext{};
    const panes = [_]PaneStatusInfo{
        .{ .pane_number = 1, .state = .idle, .is_focused = false },
        .{ .pane_number = 2, .state = .waiting, .is_focused = true },
    };

    StatusBarRenderer.render(
        &panes,
        test_config,
        800,
        575,
        17.0,
        0,
        &testDrawRect,
        &testDrawText,
        @ptrCast(&ctx),
    );

    // 2 text calls (one per segment)
    try std.testing.expectEqual(@as(usize, 2), ctx.text_count);

    // First segment: idle color
    try std.testing.expectEqualStrings("[1:idle]", ctx.text_calls[0].getText());
    try std.testing.expectEqual(test_config.idle_color, ctx.text_calls[0].color);

    // Second segment: waiting color
    try std.testing.expectEqualStrings("[2:waiting]", ctx.text_calls[1].getText());
    try std.testing.expectEqual(test_config.waiting_color, ctx.text_calls[1].color);

    // Focused highlight for pane 2 only: bg + border + focused_bg = 3 rects
    try std.testing.expectEqual(@as(usize, 3), ctx.rect_count);
}

test "render background waiting count draws summary" {
    var ctx = TestContext{};
    const panes = [_]PaneStatusInfo{};

    StatusBarRenderer.render(
        &panes,
        test_config,
        800,
        575,
        17.0,
        2,
        &testDrawRect,
        &testDrawText,
        @ptrCast(&ctx),
    );

    // 1 text call for "2 waiting"
    try std.testing.expectEqual(@as(usize, 1), ctx.text_count);
    try std.testing.expectEqualStrings("2 waiting", ctx.text_calls[0].getText());
    try std.testing.expectEqual(test_config.waiting_color, ctx.text_calls[0].color);

    // Summary is right-aligned: x should be window_width - width - 8
    const summary_width = StatusBarRenderer.estimateTextWidth(9, 17.0);
    const expected_x: i32 = 800 - @as(i32, @intCast(summary_width)) - 8;
    try std.testing.expectEqual(expected_x, ctx.text_calls[0].x);
}

test "render zero background waiting count does not draw summary" {
    var ctx = TestContext{};
    const panes = [_]PaneStatusInfo{
        .{ .pane_number = 1, .state = .working, .is_focused = true },
    };

    StatusBarRenderer.render(
        &panes,
        test_config,
        800,
        575,
        17.0,
        0,
        &testDrawRect,
        &testDrawText,
        @ptrCast(&ctx),
    );

    // Only 1 text call (the segment), no summary
    try std.testing.expectEqual(@as(usize, 1), ctx.text_count);
    try std.testing.expectEqualStrings("[1:working]", ctx.text_calls[0].getText());
    try std.testing.expectEqual(test_config.working_color, ctx.text_calls[0].color);
}

test "segment x positions use 8px gap" {
    var ctx = TestContext{};
    const panes = [_]PaneStatusInfo{
        .{ .pane_number = 1, .state = .idle, .is_focused = false },
        .{ .pane_number = 2, .state = .working, .is_focused = false },
    };

    StatusBarRenderer.render(
        &panes,
        test_config,
        800,
        575,
        17.0,
        0,
        &testDrawRect,
        &testDrawText,
        @ptrCast(&ctx),
    );

    // First segment at x=8 (left padding)
    try std.testing.expectEqual(@as(i32, 8), ctx.text_calls[0].x);

    // Second segment at x = 8 + estimateTextWidth("[1:idle]".len, 17) + 8
    const first_width = StatusBarRenderer.estimateTextWidth(8, 17.0); // "[1:idle]" = 8 chars
    const expected_x: i32 = 8 + @as(i32, @intCast(first_width)) + 8;
    try std.testing.expectEqual(expected_x, ctx.text_calls[1].x);
}

test "text scale is 0.75" {
    var ctx = TestContext{};
    const panes = [_]PaneStatusInfo{
        .{ .pane_number = 1, .state = .idle, .is_focused = false },
    };

    StatusBarRenderer.render(
        &panes,
        test_config,
        800,
        575,
        17.0,
        0,
        &testDrawRect,
        &testDrawText,
        @ptrCast(&ctx),
    );

    try std.testing.expectEqual(@as(f32, 0.75), ctx.text_calls[0].scale);
}

test "AgentStateEnum.str returns correct strings" {
    try std.testing.expectEqualStrings("idle", AgentStateEnum.idle.str());
    try std.testing.expectEqualStrings("working", AgentStateEnum.working.str());
    try std.testing.expectEqualStrings("waiting", AgentStateEnum.waiting.str());
}
