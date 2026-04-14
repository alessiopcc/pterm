/// Search bar overlay UI for scrollback search (CORE-08).
///
/// Renders a minimal search bar at the top of the active pane:
///   - Full pane width, 1 cell-row height
///   - Query text left-aligned with xs padding (2 cols from left)
///   - Match counter right-aligned ("N of M" format)
///   - Blinking cursor at insertion point
///   - No buttons or toggles
///
/// Follows the callback-based rendering pattern from PresetPicker.zig.
const std = @import("std");
const SearchState = @import("SearchState.zig").SearchState;

pub const SearchOverlay = struct {
    pub const OverlayMetrics = struct {
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        text_x: i32,
        counter_x: i32,
        row_height: u32,
        col_width: u32,
    };

    /// Calculate overlay position and size at the top of the pane.
    pub fn computeMetrics(
        pane_x: i32,
        pane_y: i32,
        pane_w: u32,
        cell_width: f32,
        cell_height: f32,
    ) OverlayMetrics {
        const cw: u32 = @intFromFloat(@max(1.0, cell_width));
        const ch: u32 = @intFromFloat(@max(1.0, cell_height));

        // xs padding = 2 cols from edges
        const padding_cols: u32 = 2;

        return .{
            .x = pane_x,
            .y = pane_y,
            .w = pane_w,
            .h = ch,
            .text_x = pane_x + @as(i32, @intCast(padding_cols * cw)),
            .counter_x = pane_x + @as(i32, @intCast(pane_w)) - @as(i32, @intCast(14 * cw)), // "999 of 999" ~ 14 chars
            .row_height = ch,
            .col_width = cw,
        };
    }

    /// Render the search bar overlay using callback-based drawing.
    /// Decoupled from GL backend (same pattern as PresetPicker).
    pub fn render(
        search_state: *const SearchState,
        metrics: OverlayMetrics,
        colors: SearchColors,
        draw_rect_fn: *const fn (x: i32, y: i32, w: u32, h: u32, color: u32, ctx: *anyopaque) void,
        draw_text_fn: *const fn (text: []const u8, x: i32, y: i32, color: u32, ctx: *anyopaque) void,
        ctx: *anyopaque,
    ) void {
        if (!search_state.is_open) return;

        // Background bar
        draw_rect_fn(metrics.x, metrics.y, metrics.w, metrics.h, colors.bar_bg, ctx);

        // Query text
        const query = search_state.getQuery();
        if (query.len > 0) {
            draw_text_fn(query, metrics.text_x, metrics.y, colors.fg, ctx);
        }

        // Text cursor (1-cell-wide bar at insertion point)
        const cursor_x = metrics.text_x + @as(i32, @intCast(@as(u32, search_state.query_len) * metrics.col_width));
        draw_rect_fn(cursor_x, metrics.y, 2, metrics.h, colors.cursor_color, ctx);

        // Match counter ("N of M")
        var counter_buf: [32]u8 = undefined;
        const counter_text = if (search_state.total_matches > 0)
            std.fmt.bufPrint(&counter_buf, "{d} of {d}", .{
                search_state.current_match + 1,
                search_state.total_matches,
            }) catch "?"
        else if (search_state.query_len > 0)
            std.fmt.bufPrint(&counter_buf, "0 of 0", .{}) catch "0 of 0"
        else
            "";

        if (counter_text.len > 0) {
            const counter_color = if (search_state.total_matches == 0 and search_state.query_len > 0)
                colors.no_match
            else
                colors.fg;
            draw_text_fn(counter_text, metrics.counter_x, metrics.y, counter_color, ctx);
        }
    }
};

/// Colors for the search bar overlay.
pub const SearchColors = struct {
    bar_bg: u32,
    fg: u32,
    no_match: u32,
    cursor_color: u32,
};

// -------------------------------------------------------
// Tests
// -------------------------------------------------------

test "SearchOverlay: computeMetrics returns correct dimensions" {
    const m = SearchOverlay.computeMetrics(100, 50, 800, 8.0, 17.0);

    // Bar at top of pane
    try std.testing.expectEqual(@as(i32, 100), m.x);
    try std.testing.expectEqual(@as(i32, 50), m.y);
    // Full pane width, 1 cell-row height
    try std.testing.expectEqual(@as(u32, 800), m.w);
    try std.testing.expectEqual(@as(u32, 17), m.h);
    // Text x with 2-col padding: 100 + 2*8 = 116
    try std.testing.expectEqual(@as(i32, 116), m.text_x);
}

test "SearchOverlay: computeMetrics with zero cell size uses minimum 1" {
    const m = SearchOverlay.computeMetrics(0, 0, 400, 0.0, 0.0);

    try std.testing.expectEqual(@as(u32, 1), m.h);
    try std.testing.expectEqual(@as(u32, 1), m.col_width);
}

test "SearchOverlay: render does nothing when search not open" {
    var state = SearchState{};
    // state.is_open = false by default
    const m = SearchOverlay.computeMetrics(0, 0, 400, 8.0, 17.0);
    const colors = SearchColors{ .bar_bg = 0, .fg = 0, .no_match = 0, .cursor_color = 0 };

    var call_count: u32 = 0;
    const CallCount = struct {
        fn rectFn(_: i32, _: i32, _: u32, _: u32, _: u32, ctx: *anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
        fn textFn(_: []const u8, _: i32, _: i32, _: u32, ctx: *anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
    };

    SearchOverlay.render(&state, m, colors, CallCount.rectFn, CallCount.textFn, @ptrCast(&call_count));
    try std.testing.expectEqual(@as(u32, 0), call_count);
}
