/// Overlay UI for selecting and switching the active pane's shell.
///
/// Renders a centered overlay list of available system shells.
/// Navigation via Up/Down arrows, Enter to select, Escape to dismiss.
/// Uses the same callback-based GPU rendering as PresetPicker.
///
/// Per UI-SPEC:
///   - Width: max(44 columns, longest display string + 4 columns)
///   - Height: shell_count + 2 rows (header + border padding)
///   - Background: tab_bar_bg color
///   - Border: 1px pane_border color
///   - Selected row: tab_active color highlight
///   - Header: "Select Shell:"
///   - Entry format: "name -- path"
///   - Active shell marker: "* name -- path" with accent color
///   - Empty state: "No shells detected." / "Check PATH or set shell.program in config."
const std = @import("std");

pub const ShellPicker = struct {
    visible: bool = false,
    selected_idx: usize = 0,
    shell_count: usize = 0,
    active_shell_idx: usize = 0,

    pub fn open(self: *ShellPicker, shell_count: usize, active_idx: usize) void {
        self.visible = true;
        self.selected_idx = 0;
        self.shell_count = shell_count;
        self.active_shell_idx = active_idx;
    }

    pub fn close(self: *ShellPicker) void {
        self.visible = false;
    }

    pub fn moveUp(self: *ShellPicker) void {
        if (self.selected_idx > 0) self.selected_idx -= 1;
    }

    pub fn moveDown(self: *ShellPicker) void {
        if (self.selected_idx + 1 < self.shell_count) self.selected_idx += 1;
    }

    pub fn getSelectedIndex(self: *const ShellPicker) usize {
        return self.selected_idx;
    }

    /// Compute the overlay dimensions in pixels.
    pub const OverlayMetrics = struct {
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        row_height: u32,
        col_width: u32,
        content_rows: u32,
    };

    /// Calculate overlay position and size.
    pub fn computeMetrics(
        shell_count: usize,
        display_names: []const []const u8,
        cell_width: f32,
        cell_height: f32,
        window_width: u32,
        window_height: u32,
    ) OverlayMetrics {
        const cw: u32 = @intFromFloat(@max(1.0, cell_width));
        const ch: u32 = @intFromFloat(@max(1.0, cell_height));

        var max_name_len: usize = 0;
        for (display_names) |name| {
            if (name.len > max_name_len) max_name_len = name.len;
        }

        // UI-SPEC: min 44 cols (40 + 4 for "name -- path" format)
        const min_cols: u32 = 44;
        const content_cols: u32 = @intCast(@max(min_cols, max_name_len + 4));
        const overlay_w = content_cols * cw;

        const content_rows: u32 = if (shell_count == 0) 4 else @as(u32, @intCast(shell_count)) + 2;
        const overlay_h = content_rows * ch;

        const x: i32 = @intCast(@max(0, (window_width -| overlay_w) / 2));
        const y: i32 = @intCast(@max(0, (window_height -| overlay_h) / 2));

        return .{
            .x = x,
            .y = y,
            .w = overlay_w,
            .h = overlay_h,
            .row_height = ch,
            .col_width = cw,
            .content_rows = content_rows,
        };
    }

    /// Render the picker overlay using callback-based drawing.
    pub fn render(
        self: *const ShellPicker,
        display_names: []const []const u8,
        cell_width: f32,
        cell_height: f32,
        window_width: u32,
        window_height: u32,
        colors: ShellPickerColors,
        draw_rect_fn: *const fn (x: i32, y: i32, w: u32, h: u32, color: u32, ctx: *anyopaque) void,
        draw_text_fn: *const fn (text: []const u8, x: i32, y: i32, color: u32, ctx: *anyopaque) void,
        ctx: *anyopaque,
    ) void {
        if (!self.visible) return;

        const m = computeMetrics(
            self.shell_count,
            display_names,
            cell_width,
            cell_height,
            window_width,
            window_height,
        );

        // Semi-transparent backdrop
        draw_rect_fn(0, 0, window_width, window_height, colors.overlay_bg, ctx);
        // Picker background
        draw_rect_fn(m.x, m.y, m.w, m.h, colors.bg, ctx);
        // Border (1px all sides)
        draw_rect_fn(m.x, m.y, m.w, 1, colors.border, ctx);
        draw_rect_fn(m.x, m.y + @as(i32, @intCast(m.h)) - 1, m.w, 1, colors.border, ctx);
        draw_rect_fn(m.x, m.y, 1, m.h, colors.border, ctx);
        draw_rect_fn(m.x + @as(i32, @intCast(m.w)) - 1, m.y, 1, m.h, colors.border, ctx);

        if (self.shell_count == 0) {
            const msg1 = "No shells detected.";
            const msg2 = "Check PATH or set shell.program in config.";
            draw_text_fn(msg1, m.x + @as(i32, @intCast(m.col_width * 2)), m.y + @as(i32, @intCast(m.row_height)), colors.fg, ctx);
            draw_text_fn(msg2, m.x + @as(i32, @intCast(m.col_width * 2)), m.y + @as(i32, @intCast(m.row_height * 2)), colors.fg, ctx);
            return;
        }

        // Header: "Select Shell:"
        const header_y = m.y + @as(i32, @intCast(m.row_height / 4));
        draw_text_fn("Select Shell:", m.x + @as(i32, @intCast(m.col_width * 2)), header_y, colors.fg, ctx);

        // Shell list
        for (display_names, 0..) |name, i| {
            if (i >= self.shell_count) break;
            const row_y = m.y + @as(i32, @intCast((i + 1) * m.row_height));

            if (i == self.selected_idx) {
                draw_rect_fn(m.x + 1, row_y, m.w - 2, m.row_height, colors.selected, ctx);
            }

            // Active shell marker: use accent color for the asterisk-prefixed entry
            const text_color = if (i == self.active_shell_idx) colors.active_marker else colors.fg;
            draw_text_fn(name, m.x + @as(i32, @intCast(m.col_width * 2)), row_y, text_color, ctx);
        }
    }
};

/// Colors for the shell picker overlay.
pub const ShellPickerColors = struct {
    bg: u32, // tab_bar_bg
    border: u32, // pane_border
    selected: u32, // tab_active
    fg: u32, // foreground text
    overlay_bg: u32, // semi-transparent dark overlay
    active_marker: u32, // accent color for currently active shell
};

// -------------------------------------------------------
// Tests
// -------------------------------------------------------

test "ShellPicker: open/close/navigation" {
    var picker = ShellPicker{};
    try std.testing.expect(!picker.visible);

    picker.open(5, 2);
    try std.testing.expect(picker.visible);
    try std.testing.expectEqual(@as(usize, 0), picker.selected_idx);
    try std.testing.expectEqual(@as(usize, 5), picker.shell_count);
    try std.testing.expectEqual(@as(usize, 2), picker.active_shell_idx);

    picker.moveDown();
    try std.testing.expectEqual(@as(usize, 1), picker.selected_idx);
    picker.moveDown();
    picker.moveDown();
    picker.moveDown();
    try std.testing.expectEqual(@as(usize, 4), picker.selected_idx);
    picker.moveDown(); // at end, should not move
    try std.testing.expectEqual(@as(usize, 4), picker.selected_idx);

    picker.moveUp();
    try std.testing.expectEqual(@as(usize, 3), picker.selected_idx);
    picker.moveUp();
    picker.moveUp();
    picker.moveUp();
    try std.testing.expectEqual(@as(usize, 0), picker.selected_idx);
    picker.moveUp(); // at start, should not move
    try std.testing.expectEqual(@as(usize, 0), picker.selected_idx);

    try std.testing.expectEqual(@as(usize, 0), picker.getSelectedIndex());

    picker.close();
    try std.testing.expect(!picker.visible);
}

test "computeMetrics: correct dimensions with 5 shells" {
    const names = [_][]const u8{ "  bash -- /usr/bin/bash", "  zsh -- /usr/bin/zsh", "  fish -- /usr/bin/fish", "* pwsh -- /usr/bin/pwsh", "  nu -- /usr/bin/nu" };
    const m = ShellPicker.computeMetrics(
        5,
        &names,
        8.0,
        17.0,
        800,
        600,
    );
    // Width: max(44, 24+4=28) = 44 cols * 8 = 352
    try std.testing.expectEqual(@as(u32, 352), m.w);
    // Height: 5 shells + 2 = 7 rows * 17 = 119
    try std.testing.expectEqual(@as(u32, 119), m.h);
    // Centered: (800 - 352) / 2 = 224
    try std.testing.expectEqual(@as(i32, 224), m.x);
}

test "computeMetrics: empty state has 4 rows minimum" {
    const names = [_][]const u8{};
    const m = ShellPicker.computeMetrics(
        0,
        &names,
        8.0,
        17.0,
        800,
        600,
    );
    try std.testing.expectEqual(@as(u32, 4), m.content_rows);
}
