/// Per-pane URL hover state.
///
/// Tracks detected URLs in the visible viewport and the currently
/// hovered URL (if mouse is over one). Used by the render loop to
/// draw underlines and by the input handler to open URLs on Ctrl+Click.
const std = @import("std");
const UrlDetector = @import("UrlDetector.zig");
const UrlRange = UrlDetector.UrlRange;

pub const UrlState = struct {
    /// All URLs detected in the current visible viewport.
    detected_urls: []const UrlRange = &.{},
    /// The allocator used for the detected_urls slice (for cleanup).
    detected_allocator: ?std.mem.Allocator = null,

    /// Currently hovered URL range (null if mouse is not over any URL).
    hovered_url: ?UrlRange = null,

    /// UTF-8 string of the hovered URL.
    hovered_url_str: [2048]u8 = [_]u8{0} ** 2048,
    hovered_url_len: u16 = 0,

    /// Whether the GLFW cursor is currently set to pointing hand.
    cursor_is_hand: bool = false,

    /// Update detected URLs from the render pipeline.
    /// Takes ownership of the new slice; frees the previous one.
    pub fn updateDetected(self: *UrlState, urls: []const UrlRange, allocator: std.mem.Allocator) void {
        if (self.detected_allocator) |alloc| {
            if (self.detected_urls.len > 0) {
                alloc.free(self.detected_urls);
            }
        }
        self.detected_urls = urls;
        self.detected_allocator = allocator;
    }

    /// Update hover state based on mouse position (cell coordinates).
    /// If mouse is within a detected URL range, sets hovered_url.
    /// Otherwise clears it.
    pub fn updateHover(self: *UrlState, mouse_row: u32, mouse_col: u16) void {
        for (self.detected_urls) |url| {
            if (url.row == mouse_row and mouse_col >= url.col_start and mouse_col < url.col_end) {
                self.hovered_url = url;
                return;
            }
        }
        self.hovered_url = null;
    }

    /// Update hover and also extract the URL string from the provided line data.
    pub fn updateHoverWithLine(self: *UrlState, mouse_row: u32, mouse_col: u16, line: ?[]const u21) void {
        self.updateHover(mouse_row, mouse_col);
        if (self.hovered_url) |url| {
            if (line) |l| {
                const result = UrlDetector.extractUrlString(l, url, &self.hovered_url_str);
                self.hovered_url_len = @intCast(result.len);
            }
        } else {
            self.hovered_url_len = 0;
        }
    }

    /// Get the hovered URL as a UTF-8 string slice, or null.
    pub fn getHoveredUrl(self: *const UrlState) ?[]const u8 {
        if (self.hovered_url == null) return null;
        if (self.hovered_url_len == 0) return null;
        return self.hovered_url_str[0..self.hovered_url_len];
    }

    /// Clear hover state.
    pub fn clearHover(self: *UrlState) void {
        self.hovered_url = null;
        self.hovered_url_len = 0;
        self.cursor_is_hand = false;
    }

    /// Free owned resources.
    pub fn deinit(self: *UrlState) void {
        if (self.detected_allocator) |alloc| {
            if (self.detected_urls.len > 0) {
                alloc.free(self.detected_urls);
            }
        }
        self.detected_urls = &.{};
        self.detected_allocator = null;
        self.clearHover();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "UrlState.updateHover sets hovered_url when within range" {
    var state = UrlState{};
    const urls = [_]UrlRange{
        .{ .row = 0, .col_start = 5, .col_end = 20 },
        .{ .row = 1, .col_start = 0, .col_end = 15 },
    };
    state.detected_urls = &urls;

    state.updateHover(0, 10);
    try std.testing.expect(state.hovered_url != null);
    try std.testing.expectEqual(@as(u16, 5), state.hovered_url.?.col_start);
    try std.testing.expectEqual(@as(u16, 20), state.hovered_url.?.col_end);
}

test "UrlState.updateHover clears hovered_url when outside all ranges" {
    var state = UrlState{};
    const urls = [_]UrlRange{
        .{ .row = 0, .col_start = 5, .col_end = 20 },
    };
    state.detected_urls = &urls;

    // First hover within range
    state.updateHover(0, 10);
    try std.testing.expect(state.hovered_url != null);

    // Then move outside
    state.updateHover(0, 25);
    try std.testing.expect(state.hovered_url == null);

    // Different row
    state.updateHover(1, 10);
    try std.testing.expect(state.hovered_url == null);
}

test "UrlState.clearHover resets all hover state" {
    var state = UrlState{};
    state.hovered_url = UrlRange{ .row = 0, .col_start = 0, .col_end = 10 };
    state.hovered_url_len = 5;
    state.cursor_is_hand = true;

    state.clearHover();
    try std.testing.expect(state.hovered_url == null);
    try std.testing.expectEqual(@as(u16, 0), state.hovered_url_len);
    try std.testing.expectEqual(false, state.cursor_is_hand);
}

test "UrlState.getHoveredUrl returns null when no hover" {
    const state = UrlState{};
    try std.testing.expect(state.getHoveredUrl() == null);
}
