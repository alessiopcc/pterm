/// Pixel rectangle for pane bounds computation.
/// Used by the binary tree layout system to define pane areas within the window.
const std = @import("std");

pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,

    /// Snap rectangle coordinates and dimensions to cell grid boundaries.
    /// x/y snap to floor(value / cell_size) * cell_size.
    /// w/h snap to floor(value / cell_size) * cell_size.
    pub fn snapToGrid(self: Rect, cell_w: f32, cell_h: f32) Rect {
        if (cell_w <= 0 or cell_h <= 0) return self;
        const fw: f32 = @floatFromInt(self.w);
        const fh: f32 = @floatFromInt(self.h);
        // Only snap width/height to cell grid. Keep x/y unchanged —
        // origin is set by the layout and must not shift to a cell boundary.
        return .{
            .x = self.x,
            .y = self.y,
            .w = @intFromFloat(@max(0, @floor(fw / cell_w) * cell_w)),
            .h = @intFromFloat(@max(0, @floor(fh / cell_h) * cell_h)),
        };
    }

    /// Check whether a pixel coordinate falls within this rectangle.
    pub fn contains(self: Rect, px: i32, py: i32) bool {
        const right: i32 = self.x + @as(i32, @intCast(self.w));
        const bottom: i32 = self.y + @as(i32, @intCast(self.h));
        return px >= self.x and px < right and py >= self.y and py < bottom;
    }

    /// Compute the number of columns given a cell width.
    pub fn cols(self: Rect, cell_w: f32) u32 {
        if (cell_w <= 0) return 0;
        return @intFromFloat(@floor(@as(f32, @floatFromInt(self.w)) / cell_w));
    }

    /// Compute the number of rows given a cell height.
    pub fn rows(self: Rect, cell_h: f32) u32 {
        if (cell_h <= 0) return 0;
        return @intFromFloat(@floor(@as(f32, @floatFromInt(self.h)) / cell_h));
    }

    /// Center point of the rectangle.
    pub fn centerX(self: Rect) i32 {
        return self.x + @as(i32, @intCast(self.w / 2));
    }

    pub fn centerY(self: Rect) i32 {
        return self.y + @as(i32, @intCast(self.h / 2));
    }
};

// -------------------------------------------------------
// Inline Tests
// -------------------------------------------------------

test "Rect.snapToGrid basic" {
    const r = Rect{ .x = 13, .y = 27, .w = 105, .h = 53 };
    const snapped = r.snapToGrid(10.0, 20.0);
    // x/y are preserved unchanged — only w/h snap to cell grid
    try std.testing.expectEqual(@as(i32, 13), snapped.x);
    try std.testing.expectEqual(@as(i32, 27), snapped.y);
    try std.testing.expectEqual(@as(u32, 100), snapped.w);
    try std.testing.expectEqual(@as(u32, 40), snapped.h);
}

test "Rect.snapToGrid zero cell size returns unchanged" {
    const r = Rect{ .x = 10, .y = 20, .w = 100, .h = 50 };
    const snapped = r.snapToGrid(0.0, 0.0);
    try std.testing.expectEqual(r.x, snapped.x);
    try std.testing.expectEqual(r.w, snapped.w);
}

test "Rect.contains inside" {
    const r = Rect{ .x = 10, .y = 20, .w = 100, .h = 50 };
    try std.testing.expect(r.contains(50, 40));
}

test "Rect.contains on boundary" {
    const r = Rect{ .x = 10, .y = 20, .w = 100, .h = 50 };
    try std.testing.expect(r.contains(10, 20)); // top-left inclusive
    try std.testing.expect(!r.contains(110, 70)); // bottom-right exclusive
}

test "Rect.contains outside" {
    const r = Rect{ .x = 10, .y = 20, .w = 100, .h = 50 };
    try std.testing.expect(!r.contains(5, 40));
    try std.testing.expect(!r.contains(50, 75));
}

test "Rect.cols and rows" {
    const r = Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    try std.testing.expectEqual(@as(u32, 80), r.cols(10.0));
    try std.testing.expectEqual(@as(u32, 30), r.rows(20.0));
}
