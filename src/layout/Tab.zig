/// Tab: owns a PaneTree root and tracks the focused pane.
///
/// Each tab starts as a single pane. Splitting and closing operations
/// delegate to tree_ops. The tab tracks its own pane_id counter.
const std = @import("std");
const PaneTree = @import("PaneTree.zig");
const PaneNode = PaneTree.PaneNode;
const SplitDirection = PaneTree.SplitDirection;
const tree_ops = @import("tree_ops.zig");
const Rect = @import("Rect.zig").Rect;

pub const Tab = struct {
    root: *PaneNode,
    focused_pane_id: u32,
    next_pane_id: u32,
    allocator: std.mem.Allocator,
    title: [128]u8,
    title_len: u32,
    has_activity: bool,
    is_zoomed: bool,
    zoom_saved_root: ?*PaneNode,

    /// Create a new tab with a single root pane.
    pub fn init(allocator: std.mem.Allocator) !Tab {
        const root = try PaneTree.createLeaf(allocator, 0, null);
        return .{
            .root = root,
            .focused_pane_id = 0,
            .next_pane_id = 1,
            .allocator = allocator,
            .title = [_]u8{0} ** 128,
            .title_len = 0,
            .has_activity = false,
            .is_zoomed = false,
            .zoom_saved_root = null,
        };
    }

    /// Free all tree nodes owned by this tab.
    pub fn deinit(self: *Tab) void {
        PaneTree.destroyNode(self.allocator, self.root);
        if (self.zoom_saved_root) |saved| {
            PaneTree.destroyNode(self.allocator, saved);
        }
    }

    /// Split the focused pane in the given direction.
    /// Returns the new pane's id, or error if the focused pane cannot be found.
    pub fn splitFocused(self: *Tab, direction: SplitDirection) !u32 {
        const leaf = tree_ops.findLeaf(self.root, self.focused_pane_id) orelse
            return error.PaneNotFound;
        const new_id = self.next_pane_id;
        _ = try tree_ops.split(self.allocator, leaf, direction, new_id);
        self.next_pane_id += 1;
        self.focused_pane_id = new_id;
        return new_id;
    }

    /// Close the focused pane.
    /// Returns the new focused pane_id, or null if this was the last pane in the tab.
    pub fn closeFocused(self: *Tab) ?u32 {
        const leaf = tree_ops.findLeaf(self.root, self.focused_pane_id) orelse return null;
        const result = tree_ops.close(self.allocator, leaf);
        if (result) |new_focus| {
            self.focused_pane_id = new_focus;
        }
        return result;
    }

    /// Get the count of panes in this tab.
    pub fn paneCount(self: *Tab) usize {
        const leaves = tree_ops.collectLeaves(self.root, self.allocator) catch return 1;
        defer self.allocator.free(leaves);
        return leaves.len;
    }

    /// Set tab title from a byte slice.
    pub fn setTitle(self: *Tab, text: []const u8) void {
        const len = @min(text.len, self.title.len);
        @memcpy(self.title[0..len], text[0..len]);
        self.title_len = @intCast(len);
    }
};

// -------------------------------------------------------
// Inline Tests
// -------------------------------------------------------

test "Tab.init creates single pane" {
    const alloc = std.testing.allocator;
    var tab = try Tab.init(alloc);
    defer tab.deinit();

    try std.testing.expectEqual(@as(u32, 0), tab.focused_pane_id);
    try std.testing.expectEqual(@as(u32, 1), tab.next_pane_id);
    try std.testing.expectEqual(@as(u32, 0), tab.root.leaf.pane_id);
}

test "Tab.splitFocused creates new pane" {
    const alloc = std.testing.allocator;
    var tab = try Tab.init(alloc);
    defer tab.deinit();

    const new_id = try tab.splitFocused(.vertical);
    try std.testing.expectEqual(@as(u32, 1), new_id);
    try std.testing.expectEqual(@as(u32, 1), tab.focused_pane_id); // focus moves to new pane
    try std.testing.expectEqual(@as(u32, 2), tab.next_pane_id);
}

test "Tab.closeFocused returns sibling" {
    const alloc = std.testing.allocator;
    var tab = try Tab.init(alloc);
    defer tab.deinit();

    _ = try tab.splitFocused(.vertical);
    // Focus is on pane 1, close it
    const result = tab.closeFocused();
    try std.testing.expectEqual(@as(?u32, 0), result);
    try std.testing.expectEqual(@as(u32, 0), tab.focused_pane_id);
}

test "Tab.closeFocused on last pane returns null" {
    const alloc = std.testing.allocator;
    var tab = try Tab.init(alloc);
    defer tab.deinit();

    const result = tab.closeFocused();
    try std.testing.expect(result == null);
}

test "Tab.paneCount" {
    const alloc = std.testing.allocator;
    var tab = try Tab.init(alloc);
    defer tab.deinit();

    try std.testing.expectEqual(@as(usize, 1), tab.paneCount());
    _ = try tab.splitFocused(.vertical);
    try std.testing.expectEqual(@as(usize, 2), tab.paneCount());
}

test "Tab.setTitle" {
    const alloc = std.testing.allocator;
    var tab = try Tab.init(alloc);
    defer tab.deinit();

    tab.setTitle("hello");
    try std.testing.expectEqual(@as(u32, 5), tab.title_len);
    try std.testing.expectEqualSlices(u8, "hello", tab.title[0..5]);
}
