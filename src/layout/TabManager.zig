/// Tab list management: create, close, switch, reorder.
///
/// Manages a list of Tabs with an active tab index. Supports all tab lifecycle
/// operations needed by the multi-pane terminal.
const std = @import("std");
const Tab = @import("Tab.zig").Tab;

/// Result of closing a tab.
pub const CloseResult = enum {
    /// Tab closed, another tab exists and is now active.
    closed,
    /// Last tab closed — application should exit.
    last_tab_closed,
};

pub const TabManager = struct {
    tabs: std.ArrayListUnmanaged(Tab),
    active_idx: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TabManager {
        return .{
            .tabs = .{},
            .active_idx = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TabManager) void {
        for (self.tabs.items) |*tab| {
            tab.deinit();
        }
        self.tabs.deinit(self.allocator);
    }

    /// Create a new tab and make it active.
    /// Returns a pointer to the newly created tab.
    pub fn createTab(self: *TabManager) !*Tab {
        const tab = try Tab.init(self.allocator);
        try self.tabs.append(self.allocator, tab);
        self.active_idx = self.tabs.items.len - 1;
        return &self.tabs.items[self.active_idx];
    }

    /// Close a tab at the given index.
    pub fn closeTab(self: *TabManager, idx: usize) CloseResult {
        if (idx >= self.tabs.items.len) return .closed;

        if (self.tabs.items.len == 1) {
            self.tabs.items[0].deinit();
            self.tabs.clearRetainingCapacity();
            return .last_tab_closed;
        }

        self.tabs.items[idx].deinit();
        _ = self.tabs.orderedRemove(idx);

        // Adjust active index
        if (self.active_idx >= self.tabs.items.len) {
            self.active_idx = self.tabs.items.len - 1;
        } else if (self.active_idx > idx) {
            self.active_idx -= 1;
        }

        return .closed;
    }

    /// Switch to a tab at the given index.
    pub fn switchTab(self: *TabManager, idx: usize) void {
        if (idx < self.tabs.items.len) {
            self.active_idx = idx;
        }
    }

    /// Move the active tab one position to the left.
    pub fn moveTabLeft(self: *TabManager) void {
        if (self.tabs.items.len <= 1) return;
        const new_idx = if (self.active_idx == 0)
            self.tabs.items.len - 1
        else
            self.active_idx - 1;
        swapTabs(self, self.active_idx, new_idx);
        self.active_idx = new_idx;
    }

    /// Move the active tab one position to the right.
    pub fn moveTabRight(self: *TabManager) void {
        if (self.tabs.items.len <= 1) return;
        const new_idx = if (self.active_idx == self.tabs.items.len - 1)
            0
        else
            self.active_idx + 1;
        swapTabs(self, self.active_idx, new_idx);
        self.active_idx = new_idx;
    }

    /// Get a pointer to the active tab.
    pub fn getActiveTab(self: *TabManager) ?*Tab {
        if (self.tabs.items.len == 0) return null;
        return &self.tabs.items[self.active_idx];
    }

    /// Get a pointer to a tab by index.
    pub fn getTab(self: *TabManager, idx: usize) ?*Tab {
        if (idx >= self.tabs.items.len) return null;
        return &self.tabs.items[idx];
    }

    /// Return the number of tabs.
    pub fn tabCount(self: *const TabManager) usize {
        return self.tabs.items.len;
    }

    fn swapTabs(self: *TabManager, a: usize, b: usize) void {
        if (a == b) return;
        const tmp = self.tabs.items[a];
        self.tabs.items[a] = self.tabs.items[b];
        self.tabs.items[b] = tmp;
    }
};

// -------------------------------------------------------
// Inline Tests
// -------------------------------------------------------

test "TabManager create 3 tabs" {
    const alloc = std.testing.allocator;
    var tm = TabManager.init(alloc);
    defer tm.deinit();

    _ = try tm.createTab();
    _ = try tm.createTab();
    _ = try tm.createTab();

    try std.testing.expectEqual(@as(usize, 3), tm.tabCount());
    try std.testing.expectEqual(@as(usize, 2), tm.active_idx); // last created is active
}

test "TabManager switchTab" {
    const alloc = std.testing.allocator;
    var tm = TabManager.init(alloc);
    defer tm.deinit();

    _ = try tm.createTab();
    _ = try tm.createTab();
    _ = try tm.createTab();

    tm.switchTab(0);
    try std.testing.expectEqual(@as(usize, 0), tm.active_idx);
    tm.switchTab(1);
    try std.testing.expectEqual(@as(usize, 1), tm.active_idx);
    tm.switchTab(99); // out of bounds — no change
    try std.testing.expectEqual(@as(usize, 1), tm.active_idx);
}

test "TabManager close middle tab" {
    const alloc = std.testing.allocator;
    var tm = TabManager.init(alloc);
    defer tm.deinit();

    _ = try tm.createTab();
    _ = try tm.createTab();
    _ = try tm.createTab();

    tm.switchTab(0); // active = 0
    const result = tm.closeTab(1); // close middle
    try std.testing.expectEqual(CloseResult.closed, result);
    try std.testing.expectEqual(@as(usize, 2), tm.tabCount());
    try std.testing.expectEqual(@as(usize, 0), tm.active_idx); // unchanged
}

test "TabManager close last tab returns last_tab_closed" {
    const alloc = std.testing.allocator;
    var tm = TabManager.init(alloc);
    defer tm.deinit();

    _ = try tm.createTab();
    const result = tm.closeTab(0);
    try std.testing.expectEqual(CloseResult.last_tab_closed, result);
    try std.testing.expectEqual(@as(usize, 0), tm.tabCount());
}

test "TabManager moveTabLeft wraps" {
    const alloc = std.testing.allocator;
    var tm = TabManager.init(alloc);
    defer tm.deinit();

    _ = try tm.createTab();
    _ = try tm.createTab();
    _ = try tm.createTab();

    tm.switchTab(0);
    tm.moveTabLeft(); // wraps to end
    try std.testing.expectEqual(@as(usize, 2), tm.active_idx);
}

test "TabManager moveTabRight wraps" {
    const alloc = std.testing.allocator;
    var tm = TabManager.init(alloc);
    defer tm.deinit();

    _ = try tm.createTab();
    _ = try tm.createTab();
    _ = try tm.createTab();

    tm.switchTab(2);
    tm.moveTabRight(); // wraps to beginning
    try std.testing.expectEqual(@as(usize, 0), tm.active_idx);
}

test "TabManager getActiveTab" {
    const alloc = std.testing.allocator;
    var tm = TabManager.init(alloc);
    defer tm.deinit();

    try std.testing.expect(tm.getActiveTab() == null);
    _ = try tm.createTab();
    try std.testing.expect(tm.getActiveTab() != null);
}

test "TabManager close active tab adjusts index" {
    const alloc = std.testing.allocator;
    var tm = TabManager.init(alloc);
    defer tm.deinit();

    _ = try tm.createTab();
    _ = try tm.createTab();
    _ = try tm.createTab();

    tm.switchTab(2); // active = last
    _ = tm.closeTab(2); // close active (last)
    try std.testing.expectEqual(@as(usize, 1), tm.active_idx); // adjusted to new last
}
