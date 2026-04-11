/// Compositor: orchestrates multi-pane rendering with viewport/scissor isolation.
///
/// The compositor owns the render loop that replaces Surface.renderThreadMain's
/// single-pane rendering. It is NOT a thread -- it is a set of functions called
/// from the render thread.
///
/// Render sequence per frame:
///   1. Clear full window
///   2. Render tab bar (via TabBarRenderer)
///   3. Compute available area below tab bar
///   4. computeBounds on active tab's tree
///   5. For each leaf pane: snapshot, build render state, drawFrameInRect
///   6. Render pane borders
const std = @import("std");
const layout = @import("layout.zig");
const TabManager = layout.TabManager.TabManager;
const Tab = layout.Tab.Tab;
const PaneTree = layout.PaneTree;
const PaneNode = PaneTree.PaneNode;
const tree_ops = layout.tree_ops;
const Rect = layout.Rect.Rect;
const TabBarRenderer = @import("TabBarRenderer.zig").TabBarRenderer;

/// Per-pane state: holds references to the terminal, PTY, and rendering resources
/// for a single pane. Stored in PaneRegistry, looked up by pane_id.
pub const PaneState = struct {
    /// Opaque pointer to the Surface-equivalent per-pane state.
    /// The actual type is managed by App; the Compositor treats it as opaque
    /// and passes it back to App callbacks for snapshot/render operations.
    user_data: *anyopaque,

    /// Current pixel bounds within the window (updated by computeBounds).
    bounds: Rect,
};

/// Maps pane_id -> *PaneState for O(1) lookup during rendering.
pub const PaneRegistry = std.AutoHashMapUnmanaged(u32, *PaneState);

/// Callback function type for rendering a single pane.
/// The compositor calls this for each visible pane with the pane's state and bounds.
/// The callback is responsible for: snapshot under mutex, build render state,
/// drawFrameInRect with the provided rect.
pub const RenderPaneFn = *const fn (pane: *PaneState, rect: Rect, ctx: *anyopaque) void;

pub const Compositor = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Compositor {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Compositor) void {
        _ = self;
    }

    /// Render a complete frame: tab bar, pane contents, pane borders.
    ///
    /// Parameters:
    ///   - tab_manager: provides active tab and tab list
    ///   - pane_registry: maps pane_id to PaneState
    ///   - render_pane_fn: callback invoked for each visible pane to do the actual GL rendering
    ///   - render_ctx: opaque context passed to render_pane_fn (typically *App)
    ///   - draw_filled_rect_fn: callback to draw a solid color rectangle (for borders)
    ///   - draw_rect_ctx: opaque context for draw_filled_rect_fn
    ///   - window_width: framebuffer width in pixels
    ///   - window_height: framebuffer height in pixels
    ///   - tab_bar_height: height of the tab bar in pixels
    ///   - cell_w: cell width in pixels (for computeBounds grid snapping)
    ///   - cell_h: cell height in pixels (for computeBounds grid snapping)
    ///   - border_px: pane border width in pixels
    ///   - border_color: color for inactive pane borders
    ///   - border_active_color: color for the focused pane border
    pub fn renderFrame(
        self: *Compositor,
        tab_manager: *TabManager,
        pane_registry: *PaneRegistry,
        render_pane_fn: RenderPaneFn,
        render_ctx: *anyopaque,
        draw_filled_rect_fn: *const fn (rect: Rect, color: ColorU32, ctx: *anyopaque) void,
        draw_rect_ctx: *anyopaque,
        window_width: u32,
        window_height: u32,
        tab_bar_height: u32,
        cell_w: f32,
        cell_h: f32,
        border_px: u32,
        border_color: ColorU32,
        border_active_color: ColorU32,
    ) void {
        _ = self;
        const active_tab = tab_manager.getActiveTab() orelse return;

        // Compute available area below tab bar
        const content_y: i32 = @intCast(tab_bar_height);
        const content_h: u32 = if (window_height > tab_bar_height) window_height - tab_bar_height else 0;
        const available = Rect{
            .x = 0,
            .y = content_y,
            .w = window_width,
            .h = content_h,
        };

        // Compute bounds for all panes in active tab
        tree_ops.computeBounds(active_tab.root, available, cell_w, cell_h, border_px);

        // Collect all leaf pane IDs with bounds in a single tree walk
        const leaf_infos = tree_ops.collectLeafInfos(active_tab.root, std.heap.page_allocator) catch return;
        defer std.heap.page_allocator.free(leaf_infos);

        // Render each pane
        for (leaf_infos) |li| {
            if (pane_registry.get(li.pane_id)) |pane_state| {
                pane_state.bounds = li.bounds;
                render_pane_fn(pane_state, li.bounds, render_ctx);
            }
        }

        // Render pane borders between split panes
        renderBorders(active_tab.root, active_tab.focused_pane_id, border_px, border_color, border_active_color, draw_filled_rect_fn, draw_rect_ctx);
    }

    /// Recursively render borders at branch split points.
    fn renderBorders(
        node: *PaneNode,
        focused_pane_id: u32,
        border_px: u32,
        border_color: ColorU32,
        border_active_color: ColorU32,
        draw_fn: *const fn (rect: Rect, color: ColorU32, ctx: *anyopaque) void,
        draw_ctx: *anyopaque,
    ) void {
        switch (node.*) {
            .branch => |b| {
                // Determine if the focused pane is in first or second subtree
                const focus_in_first = tree_ops.findLeaf(b.first, focused_pane_id) != null;
                const focus_in_second = tree_ops.findLeaf(b.second, focused_pane_id) != null;

                // Get the bounds of the first child's rightmost/bottommost edge
                const first_bounds = getSubtreeBounds(b.first);
                const second_bounds = getSubtreeBounds(b.second);

                // Use active color if the border is adjacent to the focused pane
                const color = if (focus_in_first or focus_in_second) border_active_color else border_color;

                switch (b.direction) {
                    .vertical => {
                        // Vertical split: border is a vertical line between first and second
                        const border_x = first_bounds.x + @as(i32, @intCast(first_bounds.w));
                        const border_y = @min(first_bounds.y, second_bounds.y);
                        const border_h = @max(first_bounds.h, second_bounds.h);
                        draw_fn(.{
                            .x = border_x,
                            .y = border_y,
                            .w = border_px,
                            .h = border_h,
                        }, color, draw_ctx);
                    },
                    .horizontal => {
                        // Horizontal split: border is a horizontal line between first and second
                        const border_y = first_bounds.y + @as(i32, @intCast(first_bounds.h));
                        const border_x = @min(first_bounds.x, second_bounds.x);
                        const border_w = @max(first_bounds.w, second_bounds.w);
                        draw_fn(.{
                            .x = border_x,
                            .y = border_y,
                            .w = border_w,
                            .h = border_px,
                        }, color, draw_ctx);
                    },
                }

                // Recurse into subtrees
                renderBorders(b.first, focused_pane_id, border_px, border_color, border_active_color, draw_fn, draw_ctx);
                renderBorders(b.second, focused_pane_id, border_px, border_color, border_active_color, draw_fn, draw_ctx);
            },
            .leaf => {},
        }
    }

    /// Get the bounding rectangle of a subtree (union of all leaf bounds).
    fn getSubtreeBounds(node: *PaneNode) Rect {
        switch (node.*) {
            .branch => |b| {
                const first = getSubtreeBounds(b.first);
                const second = getSubtreeBounds(b.second);
                const min_x = @min(first.x, second.x);
                const min_y = @min(first.y, second.y);
                const max_x = @max(first.x + @as(i32, @intCast(first.w)), second.x + @as(i32, @intCast(second.w)));
                const max_y = @max(first.y + @as(i32, @intCast(first.h)), second.y + @as(i32, @intCast(second.h)));
                return .{
                    .x = min_x,
                    .y = min_y,
                    .w = @intCast(max_x - min_x),
                    .h = @intCast(max_y - min_y),
                };
            },
            .leaf => |l| return l.bounds,
        }
    }
};

/// Packed RGBA color as u32 (0xRRGGBBAA). Used in compositor callbacks to avoid
/// importing renderer types into the layout module.
pub const ColorU32 = u32;

// -------------------------------------------------------
// Inline Tests
// -------------------------------------------------------

test "Compositor.init and deinit" {
    const alloc = std.testing.allocator;
    var comp = Compositor.init(alloc);
    comp.deinit();
}

test "PaneRegistry basic operations" {
    const alloc = std.testing.allocator;
    var registry = PaneRegistry{};
    defer registry.deinit(alloc);

    var state = PaneState{
        .user_data = undefined,
        .bounds = .{ .x = 0, .y = 0, .w = 400, .h = 300 },
    };
    try registry.put(alloc, 0, &state);
    try std.testing.expect(registry.get(0) != null);
    try std.testing.expect(registry.get(99) == null);
}
