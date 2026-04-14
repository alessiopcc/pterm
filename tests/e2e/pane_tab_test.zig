/// E2E tests: Pane/tab lifecycle.
///
/// Headless tests that instantiate the pane tree and tab data structures
/// directly without GPU or display. Tests create, split, close, and
/// navigation operations on the layout module.
const std = @import("std");
const testing = std.testing;
const layout = @import("layout");
const PaneTree = layout.PaneTree;
const PaneNode = PaneTree.PaneNode;
const SplitDirection = PaneTree.SplitDirection;
const FocusDirection = PaneTree.FocusDirection;
const tree_ops = layout.tree_ops;
const Tab = layout.Tab.Tab;
const TabManager = layout.TabManager.TabManager;

// ============================================================================
// Pane lifecycle tests
// ============================================================================

test "create and close panes" {
    const allocator = testing.allocator;

    // Create a root leaf (single pane)
    const root = try PaneTree.createLeaf(allocator, 0, null);
    defer PaneTree.destroyNode(allocator, root);

    // Split horizontally -> should give 2 panes
    const second = try tree_ops.split(allocator, root, .horizontal, 1);
    _ = second;

    // Root should now be a branch
    try testing.expect(root.* == .branch);

    // Split vertically on one child -> 3 panes
    const first_child = root.branch.first;
    try testing.expect(first_child.* == .leaf);
    const third = try tree_ops.split(allocator, first_child, .vertical, 2);
    _ = third;

    // Collect all leaves -- should be 3
    const leaves = try tree_ops.collectLeaves(root, allocator);
    defer allocator.free(leaves);
    try testing.expectEqual(@as(usize, 3), leaves.len);
}

test "close pane promotes sibling" {
    const allocator = testing.allocator;

    var tab = try Tab.init(allocator);
    defer tab.deinit();

    // Start with 1 pane (id=0)
    try testing.expectEqual(@as(usize, 1), tab.paneCount());

    // Split -> 2 panes
    const new_id = try tab.splitFocused(.horizontal);
    try testing.expectEqual(@as(usize, 2), tab.paneCount());

    // Focus the new pane and close it
    tab.focused_pane_id = new_id;
    const result = tab.closeFocused();
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 1), tab.paneCount());
}

// ============================================================================
// Tab lifecycle tests
// ============================================================================

test "tab lifecycle: create, switch, close" {
    const allocator = testing.allocator;

    var tm = TabManager.init(allocator);
    defer tm.deinit();

    // Create initial tab
    _ = try tm.createTab();
    try testing.expectEqual(@as(usize, 1), tm.tabs.items.len);
    try testing.expectEqual(@as(usize, 0), tm.active_idx);

    // Create second tab -> should be active
    _ = try tm.createTab();
    try testing.expectEqual(@as(usize, 2), tm.tabs.items.len);
    try testing.expectEqual(@as(usize, 1), tm.active_idx);

    // Switch to first tab
    tm.switchTab(0);
    try testing.expectEqual(@as(usize, 0), tm.active_idx);

    // Close second tab
    const close_result = tm.closeTab(1);
    try testing.expect(close_result == .closed);
    try testing.expectEqual(@as(usize, 1), tm.tabs.items.len);
}

test "tab lifecycle: last tab close returns signal" {
    const allocator = testing.allocator;

    var tm = TabManager.init(allocator);
    defer tm.deinit();

    _ = try tm.createTab();
    try testing.expectEqual(@as(usize, 1), tm.tabs.items.len);

    // Closing last tab -> should signal last_tab_closed
    const result = tm.closeTab(0);
    try testing.expect(result == .last_tab_closed);
}

// ============================================================================
// Pane navigation tests
// ============================================================================

test "pane navigation with directional focus" {
    const allocator = testing.allocator;

    var tab = try Tab.init(allocator);
    defer tab.deinit();

    // Create a 2-pane horizontal split
    const right_id = try tab.splitFocused(.vertical);

    // Focus is on the original (left) pane (id=0)
    tab.focused_pane_id = 0;

    // Navigate right should find the right pane
    const right_leaf = tree_ops.findLeaf(tab.root, 0);
    try testing.expect(right_leaf != null);

    if (right_leaf) |leaf| {
        const neighbor = tree_ops.focusDirectional(leaf, .right);
        if (neighbor) |id| {
            try testing.expectEqual(right_id, id);
        }
    }
}

test "pane split and count" {
    const allocator = testing.allocator;

    var tab = try Tab.init(allocator);
    defer tab.deinit();

    try testing.expectEqual(@as(usize, 1), tab.paneCount());

    // Split twice
    _ = try tab.splitFocused(.horizontal);
    try testing.expectEqual(@as(usize, 2), tab.paneCount());

    _ = try tab.splitFocused(.vertical);
    try testing.expectEqual(@as(usize, 3), tab.paneCount());
}
