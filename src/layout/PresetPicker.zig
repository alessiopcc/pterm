/// Overlay UI for selecting and activating layout presets (D-38).
///
/// Renders a centered overlay list of available layout presets.
/// Navigation via Up/Down arrows, Enter to activate, Escape to dismiss.
/// Uses the same filled-rect + glyph rendering pipeline as TabBarRenderer.
///
/// Per UI-SPEC:
///   - Width: max(40 columns, longest preset name + 4 columns)
///   - Height: preset count + 2 rows (header + border padding)
///   - Background: tab_bar_bg color
///   - Border: 1px pane_border color
///   - Selected row: tab_active color highlight
///   - Header: "Select Layout:"
///   - Empty state: "No layout presets defined."
const std = @import("std");
const LayoutPreset = @import("LayoutPreset.zig");

pub const PresetPicker = struct {
    visible: bool = false,
    selected_idx: usize = 0,
    preset_count: usize = 0,

    pub fn open(self: *PresetPicker, preset_count: usize) void {
        self.visible = true;
        self.selected_idx = 0;
        self.preset_count = preset_count;
    }

    pub fn close(self: *PresetPicker) void {
        self.visible = false;
    }

    pub fn moveUp(self: *PresetPicker) void {
        if (self.selected_idx > 0) self.selected_idx -= 1;
    }

    pub fn moveDown(self: *PresetPicker) void {
        if (self.selected_idx + 1 < self.preset_count) self.selected_idx += 1;
    }

    pub fn getSelectedIndex(self: *const PresetPicker) usize {
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
        preset_count: usize,
        preset_names: []const []const u8,
        cell_width: f32,
        cell_height: f32,
        window_width: u32,
        window_height: u32,
    ) OverlayMetrics {
        const cw: u32 = @intFromFloat(@max(1.0, cell_width));
        const ch: u32 = @intFromFloat(@max(1.0, cell_height));

        // Find longest name for width calculation
        var max_name_len: usize = 0;
        for (preset_names) |name| {
            if (name.len > max_name_len) max_name_len = name.len;
        }

        // Width: max(40, longest_name + 4) columns
        const min_cols: u32 = 40;
        const content_cols: u32 = @intCast(@max(min_cols, max_name_len + 4));
        const overlay_w = content_cols * cw;

        // Height: preset_count + 2 rows (header + bottom padding), min 4 for empty state
        const content_rows: u32 = if (preset_count == 0) 4 else @as(u32, @intCast(preset_count)) + 2;
        const overlay_h = content_rows * ch;

        // Center in window
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
    /// This decouples the layout logic from the GL backend, matching
    /// the TabBarRenderer pattern.
    pub fn render(
        self: *const PresetPicker,
        preset_names: []const []const u8,
        cell_width: f32,
        cell_height: f32,
        window_width: u32,
        window_height: u32,
        colors: PickerColors,
        draw_rect_fn: *const fn (x: i32, y: i32, w: u32, h: u32, color: u32, ctx: *anyopaque) void,
        draw_text_fn: *const fn (text: []const u8, x: i32, y: i32, color: u32, ctx: *anyopaque) void,
        ctx: *anyopaque,
    ) void {
        if (!self.visible) return;

        const m = computeMetrics(
            self.preset_count,
            preset_names,
            cell_width,
            cell_height,
            window_width,
            window_height,
        );

        // Semi-transparent background overlay (darken the entire window)
        draw_rect_fn(0, 0, window_width, window_height, colors.overlay_bg, ctx);

        // Picker background
        draw_rect_fn(m.x, m.y, m.w, m.h, colors.bg, ctx);

        // Border (1px on all sides)
        // Top
        draw_rect_fn(m.x, m.y, m.w, 1, colors.border, ctx);
        // Bottom
        draw_rect_fn(m.x, m.y + @as(i32, @intCast(m.h)) - 1, m.w, 1, colors.border, ctx);
        // Left
        draw_rect_fn(m.x, m.y, 1, m.h, colors.border, ctx);
        // Right
        draw_rect_fn(m.x + @as(i32, @intCast(m.w)) - 1, m.y, 1, m.h, colors.border, ctx);

        if (self.preset_count == 0) {
            // Empty state
            const msg1 = "No layout presets defined.";
            const msg2 = "Define presets in config: [layout.<name>]";
            draw_text_fn(msg1, m.x + @as(i32, @intCast(m.col_width * 2)), m.y + @as(i32, @intCast(m.row_height)), colors.fg, ctx);
            draw_text_fn(msg2, m.x + @as(i32, @intCast(m.col_width * 2)), m.y + @as(i32, @intCast(m.row_height * 2)), colors.fg, ctx);
            return;
        }

        // Header: "Select Layout:"
        const header_y = m.y + @as(i32, @intCast(m.row_height / 4));
        draw_text_fn("Select Layout:", m.x + @as(i32, @intCast(m.col_width * 2)), header_y, colors.fg, ctx);

        // Preset list
        for (preset_names, 0..) |name, i| {
            if (i >= self.preset_count) break;
            const row_y = m.y + @as(i32, @intCast((i + 1) * m.row_height));

            // Selection highlight
            if (i == self.selected_idx) {
                draw_rect_fn(m.x + 1, row_y, m.w - 2, m.row_height, colors.selected, ctx);
            }

            // Preset name with 2-cell padding
            draw_text_fn(name, m.x + @as(i32, @intCast(m.col_width * 2)), row_y, colors.fg, ctx);
        }
    }
};

/// Colors for the preset picker overlay.
pub const PickerColors = struct {
    bg: u32, // tab_bar_bg
    border: u32, // pane_border
    selected: u32, // tab_active
    fg: u32, // foreground text
    overlay_bg: u32, // semi-transparent dark overlay
};

// -------------------------------------------------------
// Tests
// -------------------------------------------------------

test "PresetPicker: open/close/navigation" {
    var picker = PresetPicker{};
    try std.testing.expect(!picker.visible);

    picker.open(3);
    try std.testing.expect(picker.visible);
    try std.testing.expectEqual(@as(usize, 0), picker.selected_idx);

    picker.moveDown();
    try std.testing.expectEqual(@as(usize, 1), picker.selected_idx);
    picker.moveDown();
    try std.testing.expectEqual(@as(usize, 2), picker.selected_idx);
    picker.moveDown(); // at end, should not move
    try std.testing.expectEqual(@as(usize, 2), picker.selected_idx);

    picker.moveUp();
    try std.testing.expectEqual(@as(usize, 1), picker.selected_idx);
    picker.moveUp();
    try std.testing.expectEqual(@as(usize, 0), picker.selected_idx);
    picker.moveUp(); // at start, should not move
    try std.testing.expectEqual(@as(usize, 0), picker.selected_idx);

    picker.close();
    try std.testing.expect(!picker.visible);
}

test "computeMetrics: correct dimensions" {
    const names = [_][]const u8{ "work", "dev-three-monitors" };
    const m = PresetPicker.computeMetrics(
        2,
        &names,
        8.0,
        17.0,
        800,
        600,
    );
    // Width: max(40, 18+4=22) = 40 cols * 8 = 320
    try std.testing.expectEqual(@as(u32, 320), m.w);
    // Height: 2 presets + 2 = 4 rows * 17 = 68
    try std.testing.expectEqual(@as(u32, 68), m.h);
    // Centered: (800 - 320) / 2 = 240
    try std.testing.expectEqual(@as(i32, 240), m.x);
}

test "computeMetrics: empty state" {
    const names = [_][]const u8{};
    const m = PresetPicker.computeMetrics(
        0,
        &names,
        8.0,
        17.0,
        800,
        600,
    );
    // 4 rows for empty state
    try std.testing.expectEqual(@as(u32, 4), m.content_rows);
}
