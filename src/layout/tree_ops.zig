/// Tree operations for the binary pane layout system.
///
/// All operations are free functions taking allocator + PaneNode pointers.
/// Each operation documents which D-## decision it implements.
const std = @import("std");
const PaneTree = @import("PaneTree.zig");
const PaneNode = PaneTree.PaneNode;
const BranchNode = PaneTree.BranchNode;
const LeafNode = PaneTree.LeafNode;
const SplitDirection = PaneTree.SplitDirection;
const FocusDirection = PaneTree.FocusDirection;
const Rect = @import("Rect.zig").Rect;

/// Split a leaf node into a branch with two leaf children (D-19: 50/50 split).
/// The original leaf's pane_id stays in the first child.
/// Returns a pointer to the new leaf node (second child).
pub fn split(
    allocator: std.mem.Allocator,
    leaf_node: *PaneNode,
    direction: SplitDirection,
    new_pane_id: u32,
) !*PaneNode {
    const old_leaf = leaf_node.leaf;
    const parent = old_leaf.parent;

    // Create two new leaf children
    const first_leaf = try PaneTree.createLeaf(allocator, old_leaf.pane_id, null);
    errdefer PaneTree.destroyNode(allocator, first_leaf);
    const second_leaf = try PaneTree.createLeaf(allocator, new_pane_id, null);
    errdefer PaneTree.destroyNode(allocator, second_leaf);

    // Convert the current node in-place to a branch
    leaf_node.* = .{
        .branch = .{
            .direction = direction,
            .ratio = 0.5, // D-19: always 50/50
            .first = first_leaf,
            .second = second_leaf,
            .parent = parent,
        },
    };

    // Set parent pointers on children
    first_leaf.leaf.parent = leaf_node;
    second_leaf.leaf.parent = leaf_node;

    return second_leaf;
}

/// Close a leaf node, promoting its sibling to the parent position (D-20).
/// Returns the sibling's focused pane_id, or null if this was the root.
pub fn close(allocator: std.mem.Allocator, leaf_node: *PaneNode) ?u32 {
    const parent_ptr = leaf_node.leaf.parent orelse {
        // Root leaf — nothing to close into
        return null;
    };

    const branch = parent_ptr.branch;
    const is_first = (branch.first == leaf_node);
    const sibling = if (is_first) branch.second else branch.first;

    // Get the sibling's pane_id (find first leaf in sibling subtree)
    const sibling_pane_id = firstLeafId(sibling);

    // Promote sibling to parent's position
    const grandparent = branch.parent;
    const sibling_copy = sibling.*;
    parent_ptr.* = sibling_copy;

    // Update parent pointer of promoted node
    switch (parent_ptr.*) {
        .branch => |*b| {
            b.parent = grandparent;
            // Update children's parent pointers
            setParent(b.first, parent_ptr);
            setParent(b.second, parent_ptr);
        },
        .leaf => |*l| {
            l.parent = grandparent;
        },
    }

    // Free both orphaned nodes:
    // - leaf_node: the closed leaf (heap-allocated child pointer)
    // - sibling: the promoted node whose content was copied into parent_ptr
    allocator.destroy(leaf_node);
    allocator.destroy(sibling);

    return sibling_pane_id;
}

/// Compute bounds recursively for all nodes in the tree (D-21: 1px borders).
/// Branches split the available Rect by direction+ratio, subtracting border_px
/// between children. Leaves store their computed Rect, snapped to cell grid.
pub fn computeBounds(node: *PaneNode, available: Rect, cell_w: f32, cell_h: f32, border_px: u32) void {
    switch (node.*) {
        .branch => |*b| {
            const border_i: i32 = @intCast(border_px);
            switch (b.direction) {
                .horizontal => {
                    // Split top/bottom — first gets ratio share, second gets ALL remaining
                    const usable_h = if (available.h > border_px) available.h - border_px else 0;
                    const first_h: u32 = @intFromFloat(@max(0, @as(f32, @floatFromInt(usable_h)) * b.ratio));
                    const second_h: u32 = usable_h - first_h;

                    const first_rect = Rect{
                        .x = available.x,
                        .y = available.y,
                        .w = available.w,
                        .h = first_h,
                    };
                    const second_rect = Rect{
                        .x = available.x,
                        .y = available.y + @as(i32, @intCast(first_h)) + border_i,
                        .w = available.w,
                        .h = second_h,
                    };
                    computeBounds(b.first, first_rect, cell_w, cell_h, border_px);
                    computeBounds(b.second, second_rect, cell_w, cell_h, border_px);
                },
                .vertical => {
                    // Split left/right — first gets ratio share, second gets ALL remaining
                    const usable_w = if (available.w > border_px) available.w - border_px else 0;
                    const first_w: u32 = @intFromFloat(@max(0, @as(f32, @floatFromInt(usable_w)) * b.ratio));
                    const second_w: u32 = usable_w - first_w;

                    const first_rect = Rect{
                        .x = available.x,
                        .y = available.y,
                        .w = first_w,
                        .h = available.h,
                    };
                    const second_rect = Rect{
                        .x = available.x + @as(i32, @intCast(first_w)) + border_i,
                        .y = available.y,
                        .w = second_w,
                        .h = available.h,
                    };
                    computeBounds(b.first, first_rect, cell_w, cell_h, border_px);
                    computeBounds(b.second, second_rect, cell_w, cell_h, border_px);
                },
            }
        },
        .leaf => |*l| {
            l.bounds = available.snapToGrid(cell_w, cell_h);
        },
    }
}

/// Find the nearest neighbor leaf in a given direction (D-28: no wrap-around).
/// Returns the pane_id of the neighbor, or null if no neighbor exists.
pub fn focusDirectional(current_leaf: *PaneNode, direction: FocusDirection) ?u32 {
    const bounds = current_leaf.leaf.bounds;
    const cx = bounds.centerX();
    const cy = bounds.centerY();

    // Walk up the tree to find the root
    const root = findRoot(current_leaf);

    // Collect all leaves
    var best_id: ?u32 = null;
    var best_dist: i64 = std.math.maxInt(i64);

    findBestNeighbor(root, current_leaf, direction, cx, cy, &best_id, &best_dist);
    return best_id;
}

/// Cycle forward through leaves in depth-first order.
pub fn focusNext(root: *PaneNode, current_pane_id: u32) ?u32 {
    var leaves_buf: [256]LeafInfo = undefined;
    var count: usize = 0;
    collectLeafInfo(root, &leaves_buf, &count);

    if (count == 0) return null;

    // Find current
    for (0..count) |i| {
        if (leaves_buf[i].pane_id == current_pane_id) {
            const next_idx = (i + 1) % count;
            return leaves_buf[next_idx].pane_id;
        }
    }
    return leaves_buf[0].pane_id;
}

/// Cycle backward through leaves in depth-first order.
pub fn focusPrev(root: *PaneNode, current_pane_id: u32) ?u32 {
    var leaves_buf: [256]LeafInfo = undefined;
    var count: usize = 0;
    collectLeafInfo(root, &leaves_buf, &count);

    if (count == 0) return null;

    for (0..count) |i| {
        if (leaves_buf[i].pane_id == current_pane_id) {
            const prev_idx = if (i == 0) count - 1 else i - 1;
            return leaves_buf[prev_idx].pane_id;
        }
    }
    return leaves_buf[count - 1].pane_id;
}

/// Swap two leaf nodes' pane_ids (D-30).
pub fn swap(leaf_a: *PaneNode, leaf_b: *PaneNode) void {
    const tmp = leaf_a.leaf.pane_id;
    leaf_a.leaf.pane_id = leaf_b.leaf.pane_id;
    leaf_b.leaf.pane_id = tmp;
}

/// Flip a branch's direction: horizontal <-> vertical (D-33).
pub fn rotate(branch_node: *PaneNode) void {
    switch (branch_node.*) {
        .branch => |*b| {
            b.direction = switch (b.direction) {
                .horizontal => .vertical,
                .vertical => .horizontal,
            };
        },
        .leaf => {},
    }
}

/// Recursively set all branch ratios to 0.5 (D-25).
pub fn equalize(node: *PaneNode) void {
    switch (node.*) {
        .branch => |*b| {
            b.ratio = 0.5;
            equalize(b.first);
            equalize(b.second);
        },
        .leaf => {},
    }
}

/// Collect all leaf pane_ids in depth-first order.
pub fn collectLeaves(node: *PaneNode, allocator: std.mem.Allocator) ![]u32 {
    var list = std.ArrayListUnmanaged(u32){};
    errdefer list.deinit(allocator);
    collectLeavesRecursive(node, &list, allocator) catch |err| {
        list.deinit(allocator);
        return err;
    };
    return list.toOwnedSlice(allocator);
}

/// Check whether a split would result in panes too small (UI-SPEC minimum).
/// Returns true if both resulting children would meet the minimum size.
pub fn canSplit(leaf_bounds: Rect, direction: SplitDirection, cell_w: f32, cell_h: f32, min_cols: u32, min_rows: u32) bool {
    if (cell_w <= 0 or cell_h <= 0) return false;
    switch (direction) {
        .horizontal => {
            // Split top/bottom: each child gets half height minus 1px border
            const half_h = leaf_bounds.h / 2;
            if (half_h < 2) return false;
            const child_h = half_h - 1; // border
            const child_rows = @as(u32, @intFromFloat(@floor(@as(f32, @floatFromInt(child_h)) / cell_h)));
            const child_cols = @as(u32, @intFromFloat(@floor(@as(f32, @floatFromInt(leaf_bounds.w)) / cell_w)));
            return child_cols >= min_cols and child_rows >= min_rows;
        },
        .vertical => {
            // Split left/right: each child gets half width minus 1px border
            const half_w = leaf_bounds.w / 2;
            if (half_w < 2) return false;
            const child_w = half_w - 1; // border
            const child_cols = @as(u32, @intFromFloat(@floor(@as(f32, @floatFromInt(child_w)) / cell_w)));
            const child_rows = @as(u32, @intFromFloat(@floor(@as(f32, @floatFromInt(leaf_bounds.h)) / cell_h)));
            return child_cols >= min_cols and child_rows >= min_rows;
        },
    }
}

/// Find the nearest ancestor branch whose split direction matches the given direction.
/// Useful for resize operations: when resizing pane_up/down, find the horizontal ancestor;
/// when resizing left/right, find the vertical ancestor.
pub fn findResizableBranch(leaf_node: *PaneNode, resize_dir: FocusDirection) ?*PaneNode {
    const target_split: SplitDirection = switch (resize_dir) {
        .up, .down => .horizontal,
        .left, .right => .vertical,
    };
    var current: *PaneNode = leaf_node;
    while (true) {
        const parent = switch (current.*) {
            .leaf => |l| l.parent,
            .branch => |b| b.parent,
        };
        if (parent) |p| {
            switch (p.*) {
                .branch => |b| {
                    if (b.direction == target_split) return p;
                },
                .leaf => {},
            }
            current = p;
        } else {
            return null;
        }
    }
}

/// Find the leaf node with a given pane_id in the tree.
pub fn findLeaf(node: *PaneNode, pane_id: u32) ?*PaneNode {
    switch (node.*) {
        .branch => |b| {
            return findLeaf(b.first, pane_id) orelse findLeaf(b.second, pane_id);
        },
        .leaf => |l| {
            if (l.pane_id == pane_id) return node;
            return null;
        },
    }
}

// -------------------------------------------------------
// Internal helpers
// -------------------------------------------------------

const LeafInfo = struct {
    pane_id: u32,
    node: *PaneNode,
};

fn collectLeafInfo(node: *PaneNode, buf: []LeafInfo, count: *usize) void {
    switch (node.*) {
        .branch => |b| {
            collectLeafInfo(b.first, buf, count);
            collectLeafInfo(b.second, buf, count);
        },
        .leaf => |l| {
            if (count.* < buf.len) {
                buf[count.*] = .{ .pane_id = l.pane_id, .node = node };
                count.* += 1;
            }
        },
    }
}

fn collectLeavesRecursive(node: *PaneNode, list: *std.ArrayListUnmanaged(u32), allocator: std.mem.Allocator) !void {
    switch (node.*) {
        .branch => |b| {
            try collectLeavesRecursive(b.first, list, allocator);
            try collectLeavesRecursive(b.second, list, allocator);
        },
        .leaf => |l| {
            try list.append(allocator, l.pane_id);
        },
    }
}

/// Leaf bounds for render iteration — avoids re-walking the tree per pane.
pub const LeafBounds = struct {
    pane_id: u32,
    bounds: Rect,
};

/// Collect all leaf nodes with their bounds in a single tree walk.
pub fn collectLeafInfos(node: *PaneNode, allocator: std.mem.Allocator) ![]LeafBounds {
    var list = std.ArrayListUnmanaged(LeafBounds){};
    errdefer list.deinit(allocator);
    try collectLeafBoundsRecursive(node, &list, allocator);
    return list.toOwnedSlice(allocator);
}

fn collectLeafBoundsRecursive(node: *PaneNode, list: *std.ArrayListUnmanaged(LeafBounds), allocator: std.mem.Allocator) !void {
    switch (node.*) {
        .branch => |b| {
            try collectLeafBoundsRecursive(b.first, list, allocator);
            try collectLeafBoundsRecursive(b.second, list, allocator);
        },
        .leaf => |l| {
            try list.append(allocator, .{ .pane_id = l.pane_id, .bounds = l.bounds });
        },
    }
}

fn firstLeafId(node: *PaneNode) u32 {
    switch (node.*) {
        .branch => |b| return firstLeafId(b.first),
        .leaf => |l| return l.pane_id,
    }
}

fn findRoot(node: *PaneNode) *PaneNode {
    var current = node;
    while (true) {
        const parent = switch (current.*) {
            .branch => |b| b.parent,
            .leaf => |l| l.parent,
        };
        if (parent) |p| {
            current = p;
        } else {
            return current;
        }
    }
}

fn findBestNeighbor(
    node: *PaneNode,
    current: *PaneNode,
    direction: FocusDirection,
    cx: i32,
    cy: i32,
    best_id: *?u32,
    best_dist: *i64,
) void {
    switch (node.*) {
        .branch => |b| {
            findBestNeighbor(b.first, current, direction, cx, cy, best_id, best_dist);
            findBestNeighbor(b.second, current, direction, cx, cy, best_id, best_dist);
        },
        .leaf => |l| {
            if (node == current) return;

            const nb = l.bounds;
            const ncx = nb.centerX();
            const ncy = nb.centerY();

            // Check if neighbor is in the right direction
            const valid = switch (direction) {
                .up => ncy < cy,
                .down => ncy > cy,
                .left => ncx < cx,
                .right => ncx > cx,
            };
            if (!valid) return;

            // Manhattan distance
            const dx: i64 = @as(i64, @intCast(ncx)) - @as(i64, @intCast(cx));
            const dy: i64 = @as(i64, @intCast(ncy)) - @as(i64, @intCast(cy));
            const dist = (if (dx < 0) -dx else dx) + (if (dy < 0) -dy else dy);

            if (dist < best_dist.*) {
                best_dist.* = dist;
                best_id.* = l.pane_id;
            }
        },
    }
}

/// Helper to set parent pointer on a PaneNode regardless of variant.
fn setParent(node: *PaneNode, parent: *PaneNode) void {
    switch (node.*) {
        .branch => |*b| b.parent = parent,
        .leaf => |*l| l.parent = parent,
    }
}

// -------------------------------------------------------
// Inline Tests
// -------------------------------------------------------

test "split creates branch with two leaves (D-19)" {
    const alloc = std.testing.allocator;
    const root = try PaneTree.createLeaf(alloc, 0, null);

    const new_leaf = try split(alloc, root, .vertical, 1);
    try std.testing.expectEqual(SplitDirection.vertical, root.branch.direction);
    try std.testing.expectEqual(@as(f32, 0.5), root.branch.ratio);
    try std.testing.expectEqual(@as(u32, 0), root.branch.first.leaf.pane_id);
    try std.testing.expectEqual(@as(u32, 1), new_leaf.leaf.pane_id);
    PaneTree.destroyNode(alloc, root);
}

test "split twice creates 3 leaves" {
    const alloc = std.testing.allocator;
    const root = try PaneTree.createLeaf(alloc, 0, null);
    _ = try split(alloc, root, .vertical, 1);
    // Split the second child further
    _ = try split(alloc, root.branch.second, .horizontal, 2);

    const leaves = try collectLeaves(root, alloc);
    defer alloc.free(leaves);
    try std.testing.expectEqual(@as(usize, 3), leaves.len);
    PaneTree.destroyNode(alloc, root);
}

test "close promotes sibling (D-20)" {
    const alloc = std.testing.allocator;
    const root = try PaneTree.createLeaf(alloc, 0, null);
    _ = try split(alloc, root, .vertical, 1);

    // Close the first child (pane 0) — sibling (pane 1) should expand
    const first_child = root.branch.first;
    const result = close(alloc, first_child);
    try std.testing.expectEqual(@as(?u32, 1), result);
    // Root should now be a leaf with pane_id 1
    try std.testing.expectEqual(@as(u32, 1), root.leaf.pane_id);
    PaneTree.destroyNode(alloc, root);
}

test "computeBounds produces non-overlapping rects" {
    const alloc = std.testing.allocator;
    const root = try PaneTree.createLeaf(alloc, 0, null);
    _ = try split(alloc, root, .vertical, 1);

    const area = Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    computeBounds(root, area, 10.0, 20.0, 1);

    const r1 = root.branch.first.leaf.bounds;
    const r2 = root.branch.second.leaf.bounds;

    // Non-overlapping: r1 right edge < r2 left edge (or equal)
    const r1_right = r1.x + @as(i32, @intCast(r1.w));
    try std.testing.expect(r1_right <= r2.x);
    // Total width used should be <= available (accounting for border)
    try std.testing.expect(r1.w + r2.w + 1 <= 800);

    PaneTree.destroyNode(alloc, root);
}

test "focusDirectional finds correct neighbor (D-28)" {
    const alloc = std.testing.allocator;
    const root = try PaneTree.createLeaf(alloc, 0, null);
    _ = try split(alloc, root, .vertical, 1);

    const area = Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    computeBounds(root, area, 10.0, 20.0, 1);

    // From left pane (0), right should find pane 1
    const right_neighbor = focusDirectional(root.branch.first, .right);
    try std.testing.expectEqual(@as(?u32, 1), right_neighbor);

    // From right pane (1), left should find pane 0
    const left_neighbor = focusDirectional(root.branch.second, .left);
    try std.testing.expectEqual(@as(?u32, 0), left_neighbor);

    // From left pane (0), left should find nothing (no wrap, D-28)
    const no_neighbor = focusDirectional(root.branch.first, .left);
    try std.testing.expect(no_neighbor == null);

    PaneTree.destroyNode(alloc, root);
}

test "focusNext/focusPrev cycle through leaves" {
    const alloc = std.testing.allocator;
    const root = try PaneTree.createLeaf(alloc, 0, null);
    _ = try split(alloc, root, .vertical, 1);
    _ = try split(alloc, root.branch.second, .horizontal, 2);

    try std.testing.expectEqual(@as(?u32, 1), focusNext(root, 0));
    try std.testing.expectEqual(@as(?u32, 2), focusNext(root, 1));
    try std.testing.expectEqual(@as(?u32, 0), focusNext(root, 2)); // wraps

    try std.testing.expectEqual(@as(?u32, 2), focusPrev(root, 0)); // wraps
    try std.testing.expectEqual(@as(?u32, 0), focusPrev(root, 1));
    try std.testing.expectEqual(@as(?u32, 1), focusPrev(root, 2));

    PaneTree.destroyNode(alloc, root);
}

test "swap exchanges pane_ids (D-30)" {
    const alloc = std.testing.allocator;
    const root = try PaneTree.createLeaf(alloc, 0, null);
    _ = try split(alloc, root, .vertical, 1);

    swap(root.branch.first, root.branch.second);
    try std.testing.expectEqual(@as(u32, 1), root.branch.first.leaf.pane_id);
    try std.testing.expectEqual(@as(u32, 0), root.branch.second.leaf.pane_id);

    PaneTree.destroyNode(alloc, root);
}

test "rotate flips direction (D-33)" {
    const alloc = std.testing.allocator;
    const root = try PaneTree.createLeaf(alloc, 0, null);
    _ = try split(alloc, root, .vertical, 1);

    try std.testing.expectEqual(SplitDirection.vertical, root.branch.direction);
    rotate(root);
    try std.testing.expectEqual(SplitDirection.horizontal, root.branch.direction);
    rotate(root);
    try std.testing.expectEqual(SplitDirection.vertical, root.branch.direction);

    PaneTree.destroyNode(alloc, root);
}

test "equalize sets all ratios to 0.5 (D-25)" {
    const alloc = std.testing.allocator;
    const root = try PaneTree.createLeaf(alloc, 0, null);
    _ = try split(alloc, root, .vertical, 1);
    _ = try split(alloc, root.branch.second, .horizontal, 2);

    // Modify ratios
    root.branch.ratio = 0.3;
    root.branch.second.branch.ratio = 0.7;

    equalize(root);
    try std.testing.expectEqual(@as(f32, 0.5), root.branch.ratio);
    try std.testing.expectEqual(@as(f32, 0.5), root.branch.second.branch.ratio);

    PaneTree.destroyNode(alloc, root);
}

test "canSplit checks minimum pane size" {
    const big = Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    try std.testing.expect(canSplit(big, .vertical, 10.0, 20.0, 10, 3));
    try std.testing.expect(canSplit(big, .horizontal, 10.0, 20.0, 10, 3));

    // Too small to split vertically: 50px / 2 - 1 = 24px, 24/10 = 2 cols < 10
    const tiny_w = Rect{ .x = 0, .y = 0, .w = 50, .h = 600 };
    try std.testing.expect(!canSplit(tiny_w, .vertical, 10.0, 20.0, 10, 3));

    // Too small to split horizontally
    const tiny_h = Rect{ .x = 0, .y = 0, .w = 800, .h = 40 };
    try std.testing.expect(!canSplit(tiny_h, .horizontal, 10.0, 20.0, 10, 3));
}

test "collectLeaves returns all pane_ids in order" {
    const alloc = std.testing.allocator;
    const root = try PaneTree.createLeaf(alloc, 0, null);
    _ = try split(alloc, root, .vertical, 1);
    _ = try split(alloc, root.branch.second, .horizontal, 2);

    const leaves = try collectLeaves(root, alloc);
    defer alloc.free(leaves);
    try std.testing.expectEqual(@as(usize, 3), leaves.len);
    try std.testing.expectEqual(@as(u32, 0), leaves[0]);
    try std.testing.expectEqual(@as(u32, 1), leaves[1]);
    try std.testing.expectEqual(@as(u32, 2), leaves[2]);

    PaneTree.destroyNode(alloc, root);
}

test "findLeaf locates correct node" {
    const alloc = std.testing.allocator;
    const root = try PaneTree.createLeaf(alloc, 0, null);
    _ = try split(alloc, root, .vertical, 1);
    _ = try split(alloc, root.branch.second, .horizontal, 2);

    const found = findLeaf(root, 2);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u32, 2), found.?.leaf.pane_id);

    try std.testing.expect(findLeaf(root, 99) == null);

    PaneTree.destroyNode(alloc, root);
}

test "computeBounds with horizontal split" {
    const alloc = std.testing.allocator;
    const root = try PaneTree.createLeaf(alloc, 0, null);
    _ = try split(alloc, root, .horizontal, 1);

    const area = Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    computeBounds(root, area, 10.0, 20.0, 1);

    const r1 = root.branch.first.leaf.bounds;
    const r2 = root.branch.second.leaf.bounds;

    // Non-overlapping vertically
    const r1_bottom = r1.y + @as(i32, @intCast(r1.h));
    try std.testing.expect(r1_bottom <= r2.y);

    PaneTree.destroyNode(alloc, root);
}
