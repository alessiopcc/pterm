/// Action dispatch, pane operations, tab management, overlays.
const std = @import("std");
const app_mod = @import("App.zig");
const App = app_mod.App;
const PaneData = app_mod.PaneData;
const callbacks = @import("callbacks.zig");
const render = @import("render.zig");
const utils = @import("utils.zig");
const glfw = @import("zglfw");
const keybindings = @import("keybindings");
const layout_mod = @import("layout");
const shell_mod = @import("shell");
const termio_mod = @import("termio");
const pty_mod = @import("pty");
const font_types = @import("font_types");
const Surface = @import("surface").Surface;
const search_mod = @import("search");
const status_bar_mod = @import("status_bar_renderer");
const render_state = @import("render_state");

const TermIO = termio_mod.TermIO;
const TermIOConfig = termio_mod.TermIOConfig;
const Pty = pty_mod.Pty;
const FontGrid = @import("fontgrid").FontGrid;
const TabManager = layout_mod.TabManager.TabManager;
const Tab = layout_mod.Tab.Tab;
const PaneTree = layout_mod.PaneTree;
const PaneNode = PaneTree.PaneNode;
const tree_ops = layout_mod.tree_ops;
const Rect = layout_mod.Rect.Rect;
const Compositor = layout_mod.Compositor.Compositor;
const PaneRegistry = layout_mod.Compositor.PaneRegistry;
const PaneState = layout_mod.Compositor.PaneState;
const TabBarRenderer = layout_mod.TabBarRenderer.TabBarRenderer;
const LayoutPreset = layout_mod.LayoutPreset;
const PresetPicker = layout_mod.PresetPicker.PresetPicker;
const ShellPicker = layout_mod.ShellPicker.ShellPicker;
const ShellInfo = shell_mod.ShellInfo;
const StatusBarRenderer = status_bar_mod.StatusBarRenderer;
const SearchState = search_mod.SearchState.SearchState;
const matcher = search_mod.matcher;
const IdleTracker = @import("idle_tracker").IdleTracker;
const AgentState = @import("agent_state").AgentState;
const BellState = @import("bell_state").BellState;

/// Dispatch a keybinding action.
pub fn dispatchAction(self: *App, action: keybindings.Action) void {
    switch (action) {
        .copy => if (getFocusedPaneData(self)) |pd| pd.surface.copySelection(pd.scroll_offset),
        .paste => if (getFocusedPaneData(self)) |pd| pd.surface.pasteFromClipboard(),
        .increase_font_size => changeFontSize(self, 1.0),
        .decrease_font_size => changeFontSize(self, -1.0),
        .reset_font_size => resetFontSize(self),
        .scroll_page_up => if (getFocusedPaneData(self)) |pd| pd.surface.scrollPageUp(),
        .scroll_page_down => if (getFocusedPaneData(self)) |pd| pd.surface.scrollPageDown(),

        // Tab operations
        .new_tab => actionNewTab(self),
        .close_tab => actionCloseTab(self),
        .next_tab => {
            const count = self.tab_manager.tabCount();
            if (count > 1) {
                const next = (self.tab_manager.active_idx + 1) % count;
                switchToTab(self, next);
            }
        },
        .prev_tab => {
            const count = self.tab_manager.tabCount();
            if (count > 1) {
                const prev = if (self.tab_manager.active_idx == 0) count - 1 else self.tab_manager.active_idx - 1;
                switchToTab(self, prev);
            }
        },
        .goto_tab_1 => switchToTab(self, 0),
        .goto_tab_2 => switchToTab(self, 1),
        .goto_tab_3 => switchToTab(self, 2),
        .goto_tab_4 => switchToTab(self, 3),
        .goto_tab_5 => switchToTab(self, 4),
        .goto_tab_6 => switchToTab(self, 5),
        .goto_tab_7 => switchToTab(self, 6),
        .goto_tab_8 => switchToTab(self, 7),
        .goto_tab_9 => switchToTab(self, 8),
        .goto_tab_last => {
            const count = self.tab_manager.tabCount();
            if (count > 0) {
                switchToTab(self, count - 1);
            }
        },

        // Pane operations
        .split_horizontal => actionSplit(self, .horizontal),
        .split_vertical => actionSplit(self, .vertical),
        .close_pane => actionClosePane(self),

        // Focus navigation
        .focus_next_pane => {
            if (self.tab_manager.getActiveTab()) |tab| {
                if (tree_ops.focusNext(tab.root, tab.focused_pane_id)) |next_id| {
                    tab.focused_pane_id = next_id;
                    self.requestFrame();
                }
            }
        },
        .focus_prev_pane => {
            if (self.tab_manager.getActiveTab()) |tab| {
                if (tree_ops.focusPrev(tab.root, tab.focused_pane_id)) |prev_id| {
                    tab.focused_pane_id = prev_id;
                    self.requestFrame();
                }
            }
        },
        .focus_pane_up => focusDirection(self, .up),
        .focus_pane_down => focusDirection(self, .down),
        .focus_pane_left => focusDirection(self, .left),
        .focus_pane_right => focusDirection(self, .right),

        // Tab reorder
        .move_tab_left => {
            self.tab_manager.moveTabLeft();
            self.requestFrame();
        },
        .move_tab_right => {
            self.tab_manager.moveTabRight();
            self.requestFrame();
        },

        // Zoom (D-24)
        .zoom_pane => actionZoomPane(self),
        .equalize_panes => {
            if (self.tab_manager.getActiveTab()) |tab| {
                tree_ops.equalize(tab.root);
                resizeAllPanes(self);
                self.requestFrame();
            }
        },
        .rotate_split => actionRotateSplit(self),

        // Pane resize (keyboard, 1 cell per press, D-29)
        .resize_pane_up => actionResizePane(self, .up),
        .resize_pane_down => actionResizePane(self, .down),
        .resize_pane_left => actionResizePane(self, .left),
        .resize_pane_right => actionResizePane(self, .right),

        // Swap pane (D-30)
        .swap_pane_up => actionSwapDirectional(self, .up),
        .swap_pane_down => actionSwapDirectional(self, .down),
        .swap_pane_left => actionSwapDirectional(self, .left),
        .swap_pane_right => actionSwapDirectional(self, .right),

        // Break out pane to new tab (D-32)
        .break_out_pane => actionBreakOut(self),

        .open_layout_picker => {
            if (self.config.layouts.len > 0) {
                self.preset_picker.open(self.config.layouts.len);
                self.requestFrame();
            }
        },
        // Agent monitoring actions
        .toggle_agent_tab => {
            if (getFocusedPaneData(self)) |pd| {
                pd.agent_state.toggleAgentTab();
                self.requestFrame();
            }
        },
        // Shell switching
        .change_shell => actionOpenShellPicker(self),
        .scroll_to_top, .scroll_to_bottom => {},
        .search => {
            // Toggle search overlay on focused pane (viewport save/restore)
            if (getFocusedPaneData(self)) |pd| {
                if (pd.search_state.is_open) {
                    // Close search and restore viewport (D-08)
                    const saved = pd.search_state.getSavedViewport();
                    pd.search_state.close();
                    // Restore viewport position
                    const snap = pd.termio.lockTerminal();
                    defer pd.termio.unlockTerminal();
                    const scr = @constCast(snap).getScreens();
                    switch (saved) {
                        .active => scr.active.pages.scroll(.active),
                        .top => scr.active.pages.scroll(.top),
                        .row => |r| scr.active.pages.scroll(.{ .row = r }),
                    }
                } else {
                    // Open search, saving current viewport (D-08)
                    const snap = pd.termio.lockTerminal();
                    defer pd.termio.unlockTerminal();
                    const scr = @constCast(snap).getScreens();
                    const current_vp: SearchState.SavedViewport = switch (scr.active.pages.viewport) {
                        .active => .active,
                        .top => .top,
                        // For .pin, conservatively save as .active (most common case).
                        // Precise row offset computation deferred to v2.
                        .pin => .active,
                    };
                    pd.search_state.open(current_vp);
                }
                self.requestFrame();
            }
        },
        .none => {},
    }
}

/// Create a new tab with a single pane (D-13).
pub fn actionNewTab(self: *App) void {
    const tab = self.tab_manager.createTab() catch return;
    const pane_id = self.createPane(null, null, null) catch return;

    // Wire the new tab's root leaf to this pane
    tab.root.leaf.pane_id = pane_id;
    tab.focused_pane_id = pane_id;
    tab.next_pane_id = pane_id + 1;

    // Set tab_index on the pane and start TermIO
    const new_tab_idx: u32 = @intCast(self.tab_manager.tabCount() - 1);

    if (self.pane_data.get(pane_id)) |pd| {
        pd.tab_index = new_tab_idx;
        pd.termio.start() catch {};
        pd.termio.terminal.observer.onScreenChange = &callbacks.screenChangeCallback;
        pd.termio.terminal.observer.screen_change_ctx = @ptrCast(pd);
    }

    // Switch to the new tab and clear stale activity indicators
    switchToTab(self, new_tab_idx);
    resizeAllPanes(self);
    updateTabTitles(self);
    for (self.tab_manager.tabs.items) |*t| t.has_activity = false;
}

/// Close the active tab and all its panes.
pub fn actionCloseTab(self: *App) void {
    self.pane_mutex.lock();
    defer self.pane_mutex.unlock();

    const tab = self.tab_manager.getActiveTab() orelse return;

    // Destroy all panes in this tab
    const leaves = tree_ops.collectLeaves(tab.root, std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(leaves);
    for (leaves) |pane_id| {
        self.destroyPane(pane_id);
    }

    const idx = self.tab_manager.active_idx;
    const result = self.tab_manager.closeTab(idx);
    if (result == .last_tab_closed) {
        self.window.handle.setShouldClose(true);
        return;
    }
    resizeAllPanes(self);
    self.requestFrame();
}

/// Switch to a tab by index, clearing activity indicator (D-13).
pub fn switchToTab(self: *App, idx: usize) void {
    // Close overlays on tab switch (Pitfall 3: prevent acting on wrong pane)
    closeShellPicker(self);
    self.tab_manager.switchTab(idx);
    // Clear activity on the now-active tab
    if (self.tab_manager.getActiveTab()) |tab| {
        tab.has_activity = false;
        // Clear bell badges on the now-active tab's panes (D-29)
        const leaf_infos = tree_ops.collectLeafInfos(tab.root, self.allocator) catch &.{};
        defer if (leaf_infos.len > 0) self.allocator.free(leaf_infos);
        for (leaf_infos) |info| {
            if (self.pane_data.getPtr(info.pane_id)) |pd_ptr| {
                pd_ptr.*.bell_state.clearBadge();
            }
        }
    }
    self.requestFrame();
}

/// Focus a neighboring pane in the given direction.
pub fn focusDirection(self: *App, direction: PaneTree.FocusDirection) void {
    if (self.tab_manager.getActiveTab()) |tab| {
        if (tree_ops.findLeaf(tab.root, tab.focused_pane_id)) |leaf| {
            if (tree_ops.focusDirectional(leaf, direction)) |target_id| {
                tab.focused_pane_id = target_id;
                self.requestFrame();
            }
        }
    }
}

/// Split the focused pane in the given direction.
/// Checks canSplit minimum before proceeding (UI-SPEC: 10x3).
pub fn actionSplit(self: *App, direction: PaneTree.SplitDirection) void {
    const tab = self.tab_manager.getActiveTab() orelse return;
    const leaf = tree_ops.findLeaf(tab.root, tab.focused_pane_id) orelse return;
    const metrics = self.font_grid.getMetrics();

    // Check minimum size constraint (10 cols x 3 rows)
    if (!tree_ops.canSplit(leaf.leaf.bounds, direction, metrics.cell_width, metrics.cell_height, 10, 3)) {
        return;
    }

    const new_id = tab.splitFocused(direction) catch return;

    // Create pane with TermIO + PTY
    const pane_id = self.createPane(null, null, null) catch return;

    // Update the new leaf's pane_id to match the created pane
    if (tree_ops.findLeaf(tab.root, new_id)) |new_leaf| {
        new_leaf.leaf.pane_id = pane_id;
    }
    tab.focused_pane_id = pane_id;

    // Set tab_index and start the new pane's TermIO
    if (self.pane_data.get(pane_id)) |pd| {
        pd.tab_index = @intCast(self.tab_manager.active_idx);
        pd.termio.start() catch {};
        pd.termio.terminal.observer.onScreenChange = &callbacks.screenChangeCallback;
        pd.termio.terminal.observer.screen_change_ctx = @ptrCast(pd);
    }

    resizeAllPanes(self);
    updateTabTitles(self);
    self.requestFrame();
}

/// Close the focused pane (D-20, D-27).
pub fn actionClosePane(self: *App) void {
    self.pane_mutex.lock();
    defer self.pane_mutex.unlock();

    const tab = self.tab_manager.getActiveTab() orelse return;
    const old_pane_id = tab.focused_pane_id;

    const result = tab.closeFocused();
    self.destroyPane(old_pane_id);

    if (result) |_| {
        // Sibling takes focus, resize remaining panes
        resizeAllPanes(self);
        updateTabTitles(self);
        self.requestFrame();
    } else {
        // Was last pane in tab (D-27) - close the tab
        const idx = self.tab_manager.active_idx;
        const close_result = self.tab_manager.closeTab(idx);
        if (close_result == .last_tab_closed) {
            self.window.handle.setShouldClose(true);
        }
        resizeAllPanes(self);
        updateTabTitles(self);
        self.requestFrame();
    }
}

/// Toggle zoom on the focused pane (D-24).
pub fn actionZoomPane(self: *App) void {
    const tab = self.tab_manager.getActiveTab() orelse return;

    if (tab.is_zoomed) {
        // Unzoom: restore saved root
        if (tab.zoom_saved_root) |saved| {
            tab.root = saved;
            tab.zoom_saved_root = null;
        }
        tab.is_zoomed = false;
    } else {
        // Zoom: save current root, create single-leaf root for focused pane
        tab.zoom_saved_root = tab.root;
        const new_root = PaneTree.createLeaf(self.allocator, tab.focused_pane_id, null) catch return;
        tab.root = new_root;
        tab.is_zoomed = true;
    }
    resizeAllPanes(self);
    self.requestFrame();
}

/// Resize the focused pane by 1 cell in the given direction (D-29).
pub fn actionResizePane(self: *App, direction: PaneTree.FocusDirection) void {
    const tab = self.tab_manager.getActiveTab() orelse return;
    const leaf = tree_ops.findLeaf(tab.root, tab.focused_pane_id) orelse return;

    // Find the nearest ancestor branch whose split matches the resize direction
    const branch = tree_ops.findResizableBranch(leaf, direction) orelse return;
    const b = &branch.branch;

    const metrics = self.font_grid.getMetrics();

    // Compute delta as a ratio change equivalent to 1 cell
    const total_size: f32 = switch (b.direction) {
        .horizontal => @floatFromInt(render.getNodeBounds(branch).h),
        .vertical => @floatFromInt(render.getNodeBounds(branch).w),
    };
    if (total_size <= 0) return;

    const cell_size: f32 = switch (b.direction) {
        .horizontal => metrics.cell_height,
        .vertical => metrics.cell_width,
    };
    const delta = cell_size / total_size;

    // Determine sign: growing first child or second based on direction + which child has focus
    const focus_in_first = tree_ops.findLeaf(b.first, tab.focused_pane_id) != null;
    const grow_first = switch (direction) {
        .down, .right => focus_in_first,
        .up, .left => !focus_in_first,
    };

    var new_ratio = if (grow_first) b.ratio + delta else b.ratio - delta;
    new_ratio = @max(0.1, @min(0.9, new_ratio)); // Clamp
    b.ratio = new_ratio;

    resizeAllPanes(self);
    self.requestFrame();
}

/// Swap focused pane with neighbor in the given direction (D-30).
pub fn actionSwapDirectional(self: *App, direction: PaneTree.FocusDirection) void {
    const tab = self.tab_manager.getActiveTab() orelse return;
    const leaf = tree_ops.findLeaf(tab.root, tab.focused_pane_id) orelse return;
    const neighbor_id = tree_ops.focusDirectional(leaf, direction) orelse return;
    const neighbor_leaf = tree_ops.findLeaf(tab.root, neighbor_id) orelse return;

    tree_ops.swap(leaf, neighbor_leaf);
    self.requestFrame();
}

/// Rotate the split direction of the focused pane's parent branch (D-33).
pub fn actionRotateSplit(self: *App) void {
    const tab = self.tab_manager.getActiveTab() orelse return;
    const leaf = tree_ops.findLeaf(tab.root, tab.focused_pane_id) orelse return;
    if (leaf.leaf.parent) |parent| {
        tree_ops.rotate(parent);
        resizeAllPanes(self);
        self.requestFrame();
    }
}

/// Break the focused pane out into a new tab (D-32).
pub fn actionBreakOut(self: *App) void {
    const tab = self.tab_manager.getActiveTab() orelse return;
    const pane_id = tab.focused_pane_id;

    // Only break out if there's more than one pane
    if (tab.paneCount() <= 1) return;

    // Remove from current tab tree (close returns sibling focus)
    const new_focus = tab.closeFocused() orelse return;
    _ = new_focus;

    // Create new tab
    const new_tab = self.tab_manager.createTab() catch return;

    // Point the new tab's root leaf to the existing pane (don't destroy/recreate)
    new_tab.root.leaf.pane_id = pane_id;
    new_tab.focused_pane_id = pane_id;
    new_tab.next_pane_id = pane_id + 1;

    resizeAllPanes(self);
    self.requestFrame();
}

/// Recompute bounds for the active tab and resize all pane PTYs.
/// Called after any structural layout change (split, close, resize, zoom, etc).
pub fn resizeAllPanes(self: *App) void {
    // Suppress activity for 30 frames -- async PTY redraws from resize cause false positives
    self.suppress_activity_frames.store(30, .release);
    for (self.tab_manager.tabs.items) |*t| t.has_activity = false;
    // Suppress agent state transitions on ALL panes during resize
    var pd_iter = self.pane_data.iterator();
    while (pd_iter.next()) |entry| {
        entry.value_ptr.*.suppress_agent_output.store(true, .release);
    }
    const tab = self.tab_manager.getActiveTab() orelse return;
    const fb = self.window.getFramebufferSize();
    const metrics = self.font_grid.getMetrics();
    const tab_bar_height = TabBarRenderer.computeHeight(metrics.cell_height);
    const status_bar_height: u32 = if (self.config.status_bar.visible)
        StatusBarRenderer.statusBarHeight(metrics.cell_height)
    else
        0;

    const content_y: i32 = @intCast(tab_bar_height);
    const total_chrome = tab_bar_height + status_bar_height;
    const content_h: u32 = if (fb.height > total_chrome) fb.height - total_chrome else 0;
    const available = Rect{
        .x = 0,
        .y = content_y,
        .w = fb.width,
        .h = content_h,
    };

    tree_ops.computeBounds(tab.root, available, metrics.cell_width, metrics.cell_height, 1);

    // Resize each pane's TermIO/PTY to match its new bounds
    const leaves = tree_ops.collectLeaves(tab.root, std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(leaves);

    for (leaves) |pid| {
        if (self.pane_data.get(pid)) |pd| {
            if (tree_ops.findLeaf(tab.root, pid)) |leaf_node| {
                const bounds = leaf_node.leaf.bounds;
                const cols: u16 = @intFromFloat(@min(500.0, @max(1.0, @as(f32, @floatFromInt(bounds.w)) / metrics.cell_width)));
                const rows: u16 = @intFromFloat(@min(500.0, @max(1.0, @as(f32, @floatFromInt(bounds.h)) / metrics.cell_height)));
                pd.termio.resize(cols, rows) catch {};
            }
        }
    }
}

/// Update tab titles from focused pane CWD and process name (D-03, D-04).
/// Format: "N: basename: process [count] [Z]"
/// Called periodically from the render loop.
pub fn updateTabTitles(self: *App) void {
    for (self.tab_manager.tabs.items) |*tab| {
        var title_buf: [128]u8 = undefined;
        var offset: usize = 0;

        // Prefer CWD basename; fall back to process name
        if (self.pane_data.get(tab.focused_pane_id)) |pd| {
            const cwd_l = pd.cwd_len.load(.acquire);
            if (cwd_l > 0) {
                const cwd_slice = pd.cwd[0..cwd_l];
                const base = if (std.mem.lastIndexOfScalar(u8, cwd_slice, '/')) |i|
                    cwd_slice[i + 1 ..]
                else if (std.mem.lastIndexOfScalar(u8, cwd_slice, '\\')) |i|
                    cwd_slice[i + 1 ..]
                else
                    cwd_slice;
                const copy_len = @min(base.len, title_buf.len - offset);
                @memcpy(title_buf[offset .. offset + copy_len], base[0..copy_len]);
                offset += copy_len;
            } else if (pd.process_name_len > 0) {
                // No CWD -- show process name as fallback
                const pname = pd.process_name[0..pd.process_name_len];
                const copy_len = @min(pname.len, title_buf.len - offset);
                @memcpy(title_buf[offset .. offset + copy_len], pname[0..copy_len]);
                offset += copy_len;
            }
        }

        // Pane count badge "[N]" if >1 pane (D-03)
        const pcount = tab.paneCount();
        if (pcount > 1) {
            const badge = std.fmt.bufPrint(title_buf[offset..], " [{d}]", .{pcount}) catch "";
            offset += badge.len;
        }

        // Zoom badge "[Z]" (D-24)
        if (tab.is_zoomed) {
            if (offset + 4 <= title_buf.len) {
                @memcpy(title_buf[offset .. offset + 4], " [Z]");
                offset += 4;
            }
        }

        const new_title = title_buf[0..offset];
        tab.setTitle(new_title);
    }
}

/// Open the shell picker overlay (D-10: single action opens picker).
pub fn actionOpenShellPicker(self: *App) void {
    // Get the currently active pane's shell name for marking
    const current_shell_name: []const u8 = if (getFocusedPaneData(self)) |pd|
        pd.process_name[0..pd.process_name_len]
    else
        "";

    // Filter available shells (D-11, D-12, D-13)
    const result = shell_mod.filterAvailableShells(
        self.allocator,
        self.config.shell.program,
    );

    if (result.count == 0) {
        if (result.items.len > 0) self.allocator.free(result.items);
        return;
    }

    // Free any previous list (including path allocations)
    if (self.available_shells) |prev| {
        for (prev) |si| {
            if (si.path_alloc) |alloc_ptr| {
                const sentinel_len = std.mem.len(alloc_ptr);
                self.allocator.free(alloc_ptr[0 .. sentinel_len + 1]);
            }
        }
        self.allocator.free(prev);
    }
    self.available_shells = result.items;

    // Build display strings: "name -- path" or "* name -- path" for active
    var active_idx: usize = 0;
    for (result.items[0..result.count], 0..) |si, i| {
        const is_active = std.mem.eql(u8, si.name, current_shell_name);
        if (is_active) active_idx = i;

        const buf = &self.available_shell_display[i];
        const prefix: []const u8 = if (is_active) "* " else "  ";
        const display = std.fmt.bufPrint(buf, "{s}{s} -- {s}", .{ prefix, si.name, si.path }) catch "???";
        self.available_shell_display_slices[i] = display;
    }

    self.shell_picker.open(result.count, active_idx);
    self.requestFrame();
}

/// Close shell picker and free cached shell list.
pub fn closeShellPicker(self: *App) void {
    self.shell_picker.close();
    if (self.available_shells) |shells| {
        // Free path allocations from findExecutable
        for (shells) |si| {
            if (si.path_alloc) |alloc_ptr| {
                const sentinel_len = std.mem.len(alloc_ptr);
                const slice = alloc_ptr[0 .. sentinel_len + 1];
                self.allocator.free(slice);
            }
        }
        self.allocator.free(shells);
        self.available_shells = null;
    }
}

/// Kill current PTY and respawn with a new shell, preserving pane position (D-01, D-03).
/// Content is lost (D-02). Follows destroyPane ordering for teardown, createPane for spawn.
pub fn respawnShell(self: *App, pd: *PaneData, shell_name: []const u8) !void {
    // Compute actual pane dimensions from bounds (not default config)
    const metrics = self.font_grid.getMetrics();
    var actual_cols = self.config.cols();
    var actual_rows = self.config.rows();
    if (self.tab_manager.getActiveTab()) |tab| {
        if (tree_ops.findLeaf(tab.root, pd.pane_id)) |leaf_node| {
            const bounds = leaf_node.leaf.bounds;
            actual_cols = @intFromFloat(@min(500.0, @max(1.0, @as(f32, @floatFromInt(bounds.w)) / metrics.cell_width)));
            actual_rows = @intFromFloat(@min(500.0, @max(1.0, @as(f32, @floatFromInt(bounds.h)) / metrics.cell_height)));
        }
    }

    // --- TEARDOWN (same order as destroyPane) ---
    pd.termio.stop();
    pd.row_cache.invalidate();
    pd.search_state.deinit(self.allocator);
    pd.url_state.deinit();
    pd.surface.deinit();
    pd.pty.deinit();
    pd.termio.deinit();

    // --- RESPAWN (same sequence as createPane lines 487-586) ---
    pd.termio = try TermIO.init(self.allocator, TermIOConfig{
        .cols = actual_cols,
        .rows = actual_rows,
        .scrollback_lines = self.config.scrollback_lines(),
    });

    pd.pty = try Pty.init(self.allocator, .{
        .cols = actual_cols,
        .rows = actual_rows,
    });

    // Resolve and spawn the selected shell
    const shell_config = shell_mod.resolveShell(self.allocator, shell_name, null);
    defer shell_config.deinit();
    try pd.pty.spawn(shell_config.path, shell_config.args, null);
    pd.termio.attachPty(&pd.pty);

    pd.surface = try Surface.init(self.allocator, self.config, &self.window, &pd.termio, .{
        .perf_logging = self.perf_logging,
        .debug_keys = false,
    });

    // Fix up internal pointers (Pitfall 1 -- CRITICAL, same as createPane lines 580-586)
    pd.surface.termio = &pd.termio;
    pd.surface.window = &self.window;

    // Rewire observer callbacks (same as createPane lines 588-594)
    pd.termio.terminal.observer.onBell = callbacks.bellCallback;
    pd.termio.terminal.observer.bell_ctx = @ptrCast(&pd.bell_state);
    pd.termio.terminal.observer.onAgentOutput = callbacks.agentOutputCallback;
    pd.termio.terminal.observer.agent_ctx = @ptrCast(pd);

    // Update process name from new shell
    {
        const shell_path_slice = std.mem.span(shell_config.path);
        const base = if (std.mem.lastIndexOfScalar(u8, shell_path_slice, '/')) |idx|
            shell_path_slice[idx + 1 ..]
        else if (std.mem.lastIndexOfScalar(u8, shell_path_slice, '\\')) |idx|
            shell_path_slice[idx + 1 ..]
        else
            shell_path_slice;
        const name = if (std.mem.endsWith(u8, base, ".exe"))
            base[0 .. base.len - 4]
        else
            base;
        const copy_len = @min(name.len, pd.process_name.len);
        @memset(&pd.process_name, 0);
        @memcpy(pd.process_name[0..copy_len], name[0..copy_len]);
        pd.process_name_len = @intCast(copy_len);
    }

    // Reset transient pane state (D-02: content lost)
    pd.scroll_offset = 0;
    pd.surface.scroll_offset = 0;
    pd.search_state = .{};
    pd.url_state = .{};
    pd.bell_state = .{};
    pd.agent_state = .{};
    pd.needs_agent_scan = std.atomic.Value(bool).init(false);
    pd.suppress_agent_output = std.atomic.Value(bool).init(false);
    pd.idle_tracker = IdleTracker.init(
        @intCast(self.config.agent.idle_timeout),
        self.config.agent.idle_detection,
    );

    // Wire screen change callback (triggers frame request on terminal output)
    pd.termio.terminal.observer.onScreenChange = &callbacks.screenChangeCallback;
    pd.termio.terminal.observer.screen_change_ctx = @ptrCast(pd);

    // Start TermIO reader thread (must happen after attachPty and observer wiring)
    try pd.termio.start();

    std.log.info("Shell switched to '{s}' in pane {d}", .{ shell_name, pd.pane_id });
}

/// Activate a layout preset: create new tabs with the preset's pane tree.
/// Non-destructive: opens in new tab(s), preserving existing tabs (D-39).
pub fn activatePreset(self: *App, preset: *const LayoutPreset.LayoutPreset) void {
    var first_new_tab_idx: ?usize = null;

    for (preset.tabs) |tab_def| {
        // Create new tab
        const tab = self.tab_manager.createTab() catch continue;
        if (first_new_tab_idx == null) {
            first_new_tab_idx = self.tab_manager.tabCount() - 1;
        }

        if (tab_def.panes.len == 0) continue;

        // Build tree from preset panes
        const start_id = utils.generatePaneId(self);
        const build_result = LayoutPreset.buildTree(self.allocator, tab_def.panes, start_id) catch continue;

        // Replace the tab's default root with the built tree
        PaneTree.destroyNode(self.allocator, tab.root);
        tab.root = build_result.root;

        // Create actual panes (TermIO + PTY) for each leaf
        const leaves = tree_ops.collectLeaves(tab.root, self.allocator) catch continue;
        defer self.allocator.free(leaves);

        for (leaves, 0..) |pane_id, i| {
            const dir = if (i < tab_def.panes.len) tab_def.panes[i].dir else null;
            const pane_shell = if (i < tab_def.panes.len) tab_def.panes[i].shell else null;
            const pane_shell_args = if (i < tab_def.panes.len) tab_def.panes[i].shell_args else null;
            const actual_id = self.createPane(dir, pane_shell, pane_shell_args) catch continue;

            // Start TermIO reader thread and wire screen change observer
            // (createPane allocates PTY+TermIO but doesn't start them)
            if (self.pane_data.get(actual_id)) |pd| {
                pd.tab_index = @intCast(self.tab_manager.tabCount() - 1);
                pd.termio.start() catch {};
                pd.termio.terminal.observer.onScreenChange = &callbacks.screenChangeCallback;
                pd.termio.terminal.observer.screen_change_ctx = @ptrCast(pd);
            }

            // If the generated pane_id differs from what buildTree assigned,
            // update the tree leaf to match the actual pane_id
            if (actual_id != pane_id) {
                if (tree_ops.findLeaf(tab.root, pane_id)) |leaf| {
                    leaf.leaf.pane_id = actual_id;
                }
            }

            // Set focused pane to first leaf
            if (i == 0) {
                tab.focused_pane_id = actual_id;
            }

            // Execute startup command if specified (D-40)
            if (i < tab_def.panes.len) {
                if (tab_def.panes[i].cmd) |cmd| {
                    if (self.pane_data.get(actual_id)) |pd| {
                        // Write command + newline to the pane's TermIO
                        // Shell stays interactive after command runs
                        pd.termio.writeInput(cmd) catch {};
                        pd.termio.writeInput("\n") catch {};
                    }
                }
            }

            // Set agent tab flag from preset definition
            if (tab_def.agent) {
                if (self.pane_data.get(actual_id)) |pd| {
                    pd.agent_state.is_agent_tab.store(true, .release);
                }
            }
        }

        // Update tab's next_pane_id
        tab.next_pane_id = utils.generatePaneId(self);
    }

    // Switch to the first new tab
    if (first_new_tab_idx) |idx| {
        self.tab_manager.switchTab(idx);
    }
    resizeAllPanes(self);
    updateTabTitles(self);
    self.requestFrame();
}

/// Activate a named layout preset by name. Used by --layout CLI flag.
pub fn activatePresetByName(self: *App, name: []const u8) void {
    for (self.config.layouts) |*preset| {
        if (std.mem.eql(u8, preset.name, name)) {
            activatePreset(self, preset);
            return;
        }
    }
    std.log.err("Layout \"{s}\" not found in config.", .{name});
}

/// Change font size by delta points (clamped to 6-72).
pub fn changeFontSize(self: *App, delta: f32) void {
    const current_fp = self.new_font_size.load(.acquire);
    const current: f32 = @as(f32, @floatFromInt(current_fp)) / 100.0;
    var new_size = current + delta;
    new_size = @max(6.0, @min(72.0, new_size));
    const new_fp: u32 = @intFromFloat(new_size * 100.0);
    if (new_fp != current_fp) {
        self.new_font_size.store(new_fp, .release);
        self.pending_font_change.store(true, .release);
        self.requestFrame();
    }
}

/// Reset font size to configured default.
pub fn resetFontSize(self: *App) void {
    const default_fp: u32 = @intFromFloat(self.config.font_size_pt() * 100.0);
    if (self.new_font_size.load(.acquire) == default_fp) return;
    self.new_font_size.store(default_fp, .release);
    self.pending_font_change.store(true, .release);
    self.requestFrame();
}

/// Run search matching for a pane's current query against scrollback history + visible screen (D-07).
/// Extracts history rows from ghostty-vt PageList using .screen coordinates, then scans
/// visible screen lines via .active coordinates.
pub fn runSearchForPane(pd: *PaneData) void {
    const query = pd.search_state.getQuery();
    if (query.len == 0) {
        pd.search_state.clearMatches(std.heap.page_allocator);
        return;
    }

    // Lock terminal for screen access
    const snapshot = pd.termio.lockTerminal();
    defer pd.termio.unlockTerminal();

    // Collect screen lines from ghostty-vt
    const screens = @constCast(snapshot).getScreens();
    const screen = screens.active;
    const cols: u16 = @intCast(screen.pages.cols);
    const rows: u16 = @intCast(screen.pages.rows);

    // --- Extract scrollback (history) lines from ghostty-vt PageList (D-07) ---
    const total_rows = screen.pages.total_rows;
    const active_rows = screen.pages.rows;
    const history_rows: u32 = if (total_rows > active_rows) @intCast(total_rows - active_rows) else 0;
    const max_history: u32 = @min(history_rows, 10_000); // Cap to prevent huge allocations

    const alloc = std.heap.page_allocator;
    const scrollback_lines_alloc = alloc.alloc([]const u21, max_history) catch return;
    defer alloc.free(scrollback_lines_alloc);

    // Flat buffer for codepoint storage: max_history * 512 u21 values
    const cps_per_row: usize = 512;
    const scrollback_cps_flat = alloc.alloc(u21, @as(usize, max_history) * cps_per_row) catch return;
    defer alloc.free(scrollback_cps_flat);

    var sb_row: u32 = 0;
    while (sb_row < max_history) : (sb_row += 1) {
        const row_offset = @as(usize, sb_row) * cps_per_row;
        var col: u16 = 0;
        var len: usize = 0;
        while (col < cols and len < cps_per_row) : (col += 1) {
            const pin_result = screen.pages.pin(.{ .screen = .{
                .x = @intCast(col),
                .y = @intCast(sb_row),
            } }) orelse {
                scrollback_cps_flat[row_offset + len] = ' ';
                len += 1;
                continue;
            };
            const rac = pin_result.rowAndCell();
            const cp = rac.cell.codepoint();
            scrollback_cps_flat[row_offset + len] = if (cp > 0) cp else ' ';
            len += 1;
        }
        scrollback_lines_alloc[sb_row] = scrollback_cps_flat[row_offset .. row_offset + len];
    }

    // --- Extract visible screen lines using .active coordinates ---
    var screen_lines_buf: [500][]const u21 = undefined;
    var screen_cps_buf: [500][512]u21 = undefined;
    const screen_rows = @min(rows, 500);
    var row: u16 = 0;
    while (row < screen_rows) : (row += 1) {
        var col: u16 = 0;
        var len: usize = 0;
        while (col < cols and len < 512) : (col += 1) {
            const pin = screen.pages.pin(.{ .active = .{
                .x = @intCast(col),
                .y = @intCast(row),
            } }) orelse {
                screen_cps_buf[row][len] = ' ';
                len += 1;
                continue;
            };
            const rac = pin.rowAndCell();
            const cp = rac.cell.codepoint();
            screen_cps_buf[row][len] = if (cp > 0) cp else ' ';
            len += 1;
        }
        screen_lines_buf[row] = screen_cps_buf[row][0..len];
    }
    const screen_lines = screen_lines_buf[0..screen_rows];

    const matches = matcher.findMatches(scrollback_lines_alloc, screen_lines, query, alloc) catch return;
    defer alloc.free(matches);

    pd.search_state.scrollback_offset = max_history;
    pd.search_state.updateMatches(alloc, matches);
}

/// Get PaneData for the currently focused pane.
pub fn getFocusedPaneData(self: *App) ?*PaneData {
    const tab = self.tab_manager.getActiveTab() orelse return null;
    return self.pane_data.get(tab.focused_pane_id);
}
