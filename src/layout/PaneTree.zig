/// Binary tree data structure for pane layout (D-17).
///
/// Each split creates a BranchNode with two children (left/right or top/bottom).
/// Leaf nodes represent individual panes. Arbitrary nesting supported (D-18).
const std = @import("std");
const Rect = @import("Rect.zig").Rect;

/// Split direction for a branch node.
pub const SplitDirection = enum {
    horizontal, // children stacked top/bottom
    vertical, // children side by side left/right
};

/// Direction for focus navigation.
pub const FocusDirection = enum {
    up,
    down,
    left,
    right,
};

/// A node in the binary pane tree: either a branch (split) or a leaf (pane).
pub const PaneNode = union(enum) {
    branch: BranchNode,
    leaf: LeafNode,
};

/// Internal branch node with two children and a split ratio.
pub const BranchNode = struct {
    direction: SplitDirection,
    ratio: f32, // 0.0-1.0, portion allocated to first child
    first: *PaneNode,
    second: *PaneNode,
    parent: ?*PaneNode,
};

/// Terminal pane leaf node.
pub const LeafNode = struct {
    pane_id: u32,
    parent: ?*PaneNode,
    bounds: Rect,
};

/// Create a new leaf node on the heap.
pub fn createLeaf(allocator: std.mem.Allocator, pane_id: u32, parent: ?*PaneNode) !*PaneNode {
    const node = try allocator.create(PaneNode);
    node.* = .{ .leaf = .{
        .pane_id = pane_id,
        .parent = parent,
        .bounds = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    } };
    return node;
}

/// Create a new branch node on the heap.
pub fn createBranch(
    allocator: std.mem.Allocator,
    direction: SplitDirection,
    ratio: f32,
    first: *PaneNode,
    second: *PaneNode,
    parent: ?*PaneNode,
) !*PaneNode {
    const node = try allocator.create(PaneNode);
    node.* = .{ .branch = .{
        .direction = direction,
        .ratio = ratio,
        .first = first,
        .second = second,
        .parent = parent,
    } };
    return node;
}

/// Recursively free a node and all its children.
pub fn destroyNode(allocator: std.mem.Allocator, node: *PaneNode) void {
    switch (node.*) {
        .branch => |b| {
            destroyNode(allocator, b.first);
            destroyNode(allocator, b.second);
        },
        .leaf => {},
    }
    allocator.destroy(node);
}

// -------------------------------------------------------
// Inline Tests
// -------------------------------------------------------

test "createLeaf and destroyNode" {
    const alloc = std.testing.allocator;
    const leaf = try createLeaf(alloc, 42, null);
    try std.testing.expectEqual(@as(u32, 42), leaf.leaf.pane_id);
    try std.testing.expect(leaf.leaf.parent == null);
    destroyNode(alloc, leaf);
}

test "createBranch with two leaves" {
    const alloc = std.testing.allocator;
    const left = try createLeaf(alloc, 1, null);
    const right = try createLeaf(alloc, 2, null);
    const branch = try createBranch(alloc, .vertical, 0.5, left, right, null);
    // Set parent pointers
    left.leaf.parent = branch;
    right.leaf.parent = branch;

    try std.testing.expectEqual(SplitDirection.vertical, branch.branch.direction);
    try std.testing.expectEqual(@as(f32, 0.5), branch.branch.ratio);
    try std.testing.expectEqual(@as(u32, 1), branch.branch.first.leaf.pane_id);
    try std.testing.expectEqual(@as(u32, 2), branch.branch.second.leaf.pane_id);
    destroyNode(alloc, branch);
}

test "destroyNode recursively frees tree" {
    const alloc = std.testing.allocator;
    // Build a 3-leaf tree: root(branch) -> branch(l1, l2), l3
    const l1 = try createLeaf(alloc, 1, null);
    const l2 = try createLeaf(alloc, 2, null);
    const inner = try createBranch(alloc, .horizontal, 0.5, l1, l2, null);
    l1.leaf.parent = inner;
    l2.leaf.parent = inner;

    const l3 = try createLeaf(alloc, 3, null);
    const root = try createBranch(alloc, .vertical, 0.5, inner, l3, null);
    inner.branch.parent = root;
    l3.leaf.parent = root;

    // Should free all 5 nodes without leaks
    destroyNode(alloc, root);
}
