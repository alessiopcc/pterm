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
const AgentState = @import("agent_state").AgentState;
const BellState = @import("bell_state").BellState;
const process_monitor = @import("process_monitor");

/// Dispatch a keybinding action.
pub fn dispatchAction(self: *App, action: keybindings.Action) void {
    // While agent focus mode is active, structural mutations that would
    // change tabs/panes underfoot are ignored. User must exit agent mode
    // first (Esc or the toggle hotkey).
    if (self.tab_manager.agent_mode_active) {
        switch (action) {
            .close_pane, .close_tab, .new_tab, .split_horizontal, .split_vertical, .break_out_pane, .zoom_pane, .rotate_split, .equalize_panes => return,
            else => {},
        }
    }
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

        // Zoom
        .zoom_pane => actionZoomPane(self),
        .equalize_panes => {
            if (self.tab_manager.getActiveTab()) |tab| {
                tree_ops.equalize(tab.root);
                resizeAllPanes(self);
                self.requestFrame();
            }
        },
        .rotate_split => actionRotateSplit(self),

        // Pane resize (keyboard, 1 cell per press)
        .resize_pane_up => actionResizePane(self, .up),
        .resize_pane_down => actionResizePane(self, .down),
        .resize_pane_left => actionResizePane(self, .left),
        .resize_pane_right => actionResizePane(self, .right),

        // Swap pane
        .swap_pane_up => actionSwapDirectional(self, .up),
        .swap_pane_down => actionSwapDirectional(self, .down),
        .swap_pane_left => actionSwapDirectional(self, .left),
        .swap_pane_right => actionSwapDirectional(self, .right),

        // Break out pane to new tab
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
        .agent_focus_toggle => {
            if (self.tab_manager.agent_mode_active) {
                exitAgentMode(self);
            } else {
                enterAgentMode(self);
            }
        },
        .agent_focus_next => {
            if (self.tab_manager.agent_mode_active) {
                advanceAgentSource(self);
            }
        },
        // Shell switching
        .change_shell => actionOpenShellPicker(self),
        .scroll_to_top, .scroll_to_bottom => {},
        .search => {
            // Toggle search overlay on focused pane (viewport save/restore)
            if (getFocusedPaneData(self)) |pd| {
                if (pd.search_state.is_open) {
                    // Close search and restore viewport
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
                    // Open search, saving current viewport
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

/// Create a new tab with a single pane.
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
    _ = updateTabTitles(self);
    for (self.tab_manager.tabs.items) |*t| t.has_activity = false;
}

/// Close the active tab and all its panes.
pub fn actionCloseTab(self: *App) void {
    actionCloseTabByIndex(self, self.tab_manager.active_idx);
}

/// Close a specific tab by index and all its panes.
pub fn actionCloseTabByIndex(self: *App, idx: usize) void {
    self.pane_mutex.lock();
    defer self.pane_mutex.unlock();

    const tab = self.tab_manager.getTab(idx) orelse return;

    const leaves = tree_ops.collectLeaves(tab.root, self.allocator) catch return;
    defer self.allocator.free(leaves);
    for (leaves) |pane_id| {
        self.destroyPane(pane_id);
    }

    const result = self.tab_manager.closeTab(idx);
    if (result == .last_tab_closed) {
        self.window.handle.setShouldClose(true);
        return;
    }
    resizeAllPanes(self);
    self.requestFrame();
}

/// Switch to a tab by index, clearing activity indicator.
pub fn switchToTab(self: *App, idx: usize) void {
    // Close overlays on tab switch (Pitfall 3: prevent acting on wrong pane)
    closeShellPicker(self);
    // Exit agent focus mode when user explicitly picks a numbered tab
    if (self.tab_manager.agent_mode_active) {
        exitAgentMode(self);
    }
    self.tab_manager.switchTab(idx);
    // Clear activity on the now-active tab
    if (self.tab_manager.getActiveTab()) |tab| {
        tab.has_activity = false;
        // Clear bell badges on the now-active tab's panes
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

    // Inherit CWD from the focused pane's child process (live query)
    var cwd_query_buf: [512]u8 = undefined;
    const parent_cwd: ?[]const u8 = if (self.pane_data.get(tab.focused_pane_id)) |pd|
        pd.pty.getChildCwd(&cwd_query_buf)
    else
        null;

    const new_id = tab.splitFocused(direction) catch return;

    // Create pane with TermIO + PTY
    const pane_id = self.createPane(parent_cwd, null, null) catch return;

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
    _ = updateTabTitles(self);
    self.requestFrame();
}

/// Close the focused pane.
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
        _ = updateTabTitles(self);
        self.requestFrame();
    } else {
        // Was last pane in tab - close the tab
        const idx = self.tab_manager.active_idx;
        const close_result = self.tab_manager.closeTab(idx);
        if (close_result == .last_tab_closed) {
            self.window.handle.setShouldClose(true);
        }
        resizeAllPanes(self);
        _ = updateTabTitles(self);
        self.requestFrame();
    }
}

/// Close the pane with the given id (may be in any tab). If it was the last
/// pane in its tab, close that tab too. Used to reap panes whose process has exited.
pub fn actionClosePaneById(self: *App, pane_id: u32) void {
    // If the agent focus source is being closed, drop the reference now.
    // Re-pick a source on the next user advance / re-enter.
    if (self.tab_manager.agent_source) |src| {
        if (src.pane_id == pane_id) {
            self.tab_manager.agent_mode_active = false;
            self.tab_manager.agent_source = null;
        }
    }

    self.pane_mutex.lock();
    defer self.pane_mutex.unlock();

    const pd = self.pane_data.get(pane_id) orelse return;
    const tab_idx = pd.tab_index;
    const tab = self.tab_manager.getTab(tab_idx) orelse return;

    const leaf = tree_ops.findLeaf(tab.root, pane_id) orelse {
        self.destroyPane(pane_id);
        return;
    };

    const sibling_focus = tree_ops.close(self.allocator, leaf);
    self.destroyPane(pane_id);

    if (sibling_focus) |new_focus| {
        tab.focused_pane_id = new_focus;
        resizeAllPanes(self);
        _ = updateTabTitles(self);
        self.requestFrame();
        return;
    }

    // Was the last pane in the tab — close the tab.
    const close_result = self.tab_manager.closeTab(tab_idx);
    if (close_result == .last_tab_closed) {
        self.window.handle.setShouldClose(true);
        return;
    }
    resizeAllPanes(self);
    _ = updateTabTitles(self);
    self.requestFrame();
}

/// Toggle zoom on the focused pane.
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

/// Resize the focused pane by 1 cell in the given direction.
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

/// Swap focused pane with neighbor in the given direction.
pub fn actionSwapDirectional(self: *App, direction: PaneTree.FocusDirection) void {
    const tab = self.tab_manager.getActiveTab() orelse return;
    const leaf = tree_ops.findLeaf(tab.root, tab.focused_pane_id) orelse return;
    const neighbor_id = tree_ops.focusDirectional(leaf, direction) orelse return;
    const neighbor_leaf = tree_ops.findLeaf(tab.root, neighbor_id) orelse return;

    tree_ops.swap(leaf, neighbor_leaf);
    self.requestFrame();
}

/// Rotate the split direction of the focused pane's parent branch.
pub fn actionRotateSplit(self: *App) void {
    const tab = self.tab_manager.getActiveTab() orelse return;
    const leaf = tree_ops.findLeaf(tab.root, tab.focused_pane_id) orelse return;
    if (leaf.leaf.parent) |parent| {
        tree_ops.rotate(parent);
        resizeAllPanes(self);
        self.requestFrame();
    }
}

/// Break the focused pane out into a new tab.
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
    const fb = self.window.getFramebufferSize();
    // Suppress activity for 30 frames -- async PTY redraws from resize cause false positives
    self.suppress_activity_frames.store(30, .release);
    for (self.tab_manager.tabs.items) |*t| t.has_activity = false;
    // Suppress agent state transitions on ALL panes during resize
    const deadline: i64 = @as(i64, @intCast(std.time.nanoTimestamp())) + app_mod.SUPPRESS_DURATION_NS;
    var pd_iter = self.pane_data.iterator();
    while (pd_iter.next()) |entry| {
        entry.value_ptr.*.suppressAgentOutputUntil(deadline);
    }
    const metrics = self.font_grid.getMetrics();
    const tab_bar_height = TabBarRenderer.computeHeight(self.chrome_cell_height);
    const status_bar_height: u32 = if (self.config.status_bar.visible)
        StatusBarRenderer.statusBarHeight(self.chrome_cell_height)
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
    const padding = self.config.grid_padding();

    // Agent focus mode: only the source pane is visible, sized to the full
    // content rect. Skip the active-tab tree walk entirely.
    if (self.tab_manager.agent_mode_active) {
        if (self.tab_manager.agent_source) |src| {
            if (self.pane_data.get(src.pane_id)) |pd| {
                const usable_w: f32 = @as(f32, @floatFromInt(available.w)) - 2.0 * padding;
                const usable_h: f32 = @as(f32, @floatFromInt(available.h)) - 2.0 * padding;
                const cols: u16 = @intFromFloat(@min(500.0, @max(1.0, usable_w / metrics.cell_width)));
                const rows: u16 = @intFromFloat(@min(500.0, @max(1.0, usable_h / metrics.cell_height)));
                pd.termio.resize(cols, rows) catch {};
            }
        }
        return;
    }

    const tab = self.tab_manager.getActiveTab() orelse {
        std.log.warn("resizeAllPanes: no active tab", .{});
        return;
    };

    tree_ops.computeBounds(tab.root, available, metrics.cell_width, metrics.cell_height, 1);

    // Resize each pane's TermIO/PTY to match its new bounds
    const leaves = tree_ops.collectLeaves(tab.root, std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(leaves);

    for (leaves) |pid| {
        if (self.pane_data.get(pid)) |pd| {
            if (tree_ops.findLeaf(tab.root, pid)) |leaf_node| {
                const bounds = leaf_node.leaf.bounds;
                const usable_w: f32 = @as(f32, @floatFromInt(bounds.w)) - 2.0 * padding;
                const usable_h: f32 = @as(f32, @floatFromInt(bounds.h)) - 2.0 * padding;
                const cols: u16 = @intFromFloat(@min(500.0, @max(1.0, usable_w / metrics.cell_width)));
                const rows: u16 = @intFromFloat(@min(500.0, @max(1.0, usable_h / metrics.cell_height)));
                pd.termio.resize(cols, rows) catch {};
            }
        }
    }
}

// ── Agent focus mode ─────────────────────────────────────────

/// True if the pane's foreground process is in `config.agent.processes`.
fn paneIsAgentEligible(self: *App, pd: *PaneData) bool {
    const name = pd.process_name[0..pd.process_name_len];
    if (name.len == 0) return false;
    return process_monitor.nameMatchesList(name, self.config.agent.processes);
}

const Eligible = struct { tab_idx: usize, pane_id: u32, state: AgentState.State };

/// Walk all tabs in (tab_idx, pane_id) order and collect eligible panes.
/// Caller owns the returned slice (frame_arena).
fn collectEligible(self: *App, alloc: std.mem.Allocator) []Eligible {
    var list = std.ArrayListUnmanaged(Eligible){};
    for (self.tab_manager.tabs.items, 0..) |*tab, ti| {
        const leaves = tree_ops.collectLeaves(tab.root, alloc) catch continue;
        defer alloc.free(leaves);
        for (leaves) |pid| {
            const pd = self.pane_data.get(pid) orelse continue;
            if (!paneIsAgentEligible(self, pd)) continue;
            list.append(alloc, .{
                .tab_idx = ti,
                .pane_id = pid,
                .state = pd.agent_state.state.load(.acquire),
            }) catch break;
        }
    }
    return list.toOwnedSlice(alloc) catch &.{};
}

/// Pick the best eligible pane: first .waiting, else first .working, else null.
fn pickFirstEligible(eligibles: []const Eligible) ?Eligible {
    for (eligibles) |e| if (e.state == .waiting) return e;
    for (eligibles) |e| if (e.state == .working) return e;
    return null;
}

/// Pick the next eligible pane after `current`, with wrap-around. Prefers
/// .waiting over .working in the round.
fn pickNextEligible(eligibles: []const Eligible, current: AgentSource) ?Eligible {
    if (eligibles.len == 0) return null;
    var start: usize = 0;
    for (eligibles, 0..) |e, i| {
        if (e.tab_idx == current.tab_idx and e.pane_id == current.pane_id) {
            start = (i + 1) % eligibles.len;
            break;
        }
    }
    // Walk forward with wrap, preferring waiting first.
    var i: usize = 0;
    while (i < eligibles.len) : (i += 1) {
        const e = eligibles[(start + i) % eligibles.len];
        if (e.state == .waiting) return e;
    }
    i = 0;
    while (i < eligibles.len) : (i += 1) {
        const e = eligibles[(start + i) % eligibles.len];
        if (e.state == .working) return e;
    }
    return null;
}

const AgentSource = layout_mod.TabManager.AgentSource;

/// Activate the source: switch active tab + focus, set agent_mode_active,
/// resize the source pane to fullscreen.
fn activateSource(self: *App, src: AgentSource) void {
    self.tab_manager.agent_source = src;
    self.tab_manager.agent_mode_active = true;
    self.tab_manager.switchTab(src.tab_idx);
    if (self.tab_manager.getActiveTab()) |t| {
        t.focused_pane_id = src.pane_id;
    }
    resizeAllPanes(self);
    self.requestFrame();
}

/// Enter agent focus mode. Picks the first eligible pane (waiting > working).
/// No-op if no agent process is running anywhere.
pub fn enterAgentMode(self: *App) void {
    self.pane_mutex.lock();
    defer self.pane_mutex.unlock();
    if (self.tab_manager.agent_mode_active) return;

    const arena = self.frame_arena.allocator();
    const eligibles = collectEligible(self, arena);
    const pick = pickFirstEligible(eligibles) orelse return;
    activateSource(self, .{ .tab_idx = pick.tab_idx, .pane_id = pick.pane_id });
}

/// Advance to the next eligible pane. No-op if not in agent mode or no other
/// eligible pane exists.
pub fn advanceAgentSource(self: *App) void {
    self.pane_mutex.lock();
    defer self.pane_mutex.unlock();
    if (!self.tab_manager.agent_mode_active) return;
    const current = self.tab_manager.agent_source orelse return;
    const arena = self.frame_arena.allocator();
    const eligibles = collectEligible(self, arena);
    const pick = pickNextEligible(eligibles, current) orelse return;
    if (pick.tab_idx == current.tab_idx and pick.pane_id == current.pane_id) return;
    activateSource(self, .{ .tab_idx = pick.tab_idx, .pane_id = pick.pane_id });
}

/// Exit agent focus mode. Resizes the (now-active) tab's panes back to tiled.
pub fn exitAgentMode(self: *App) void {
    if (!self.tab_manager.agent_mode_active) return;
    self.tab_manager.agent_mode_active = false;
    self.tab_manager.agent_source = null;
    resizeAllPanes(self);
    self.requestFrame();
}

/// Known shell process names; comparison is case-insensitive.
const KNOWN_SHELLS = [_][]const u8{
    "pwsh",  "powershell", "cmd",  "nu",
    "bash",  "zsh",        "fish", "sh",
    "dash",  "ksh",        "tcsh", "csh",
    "xonsh", "elvish",     "nush",
};

pub fn isShellName(name: []const u8) bool {
    var n = name;
    if (n.len > 4 and std.ascii.eqlIgnoreCase(n[n.len - 4 ..], ".exe")) {
        n = n[0 .. n.len - 4];
    }
    for (KNOWN_SHELLS) |s| {
        if (std.ascii.eqlIgnoreCase(n, s)) return true;
    }
    return false;
}

/// Update tab titles from focused pane CWD and process name.
/// Format: "basename" when the foreground process is a shell, otherwise
/// "process@basename [count] [Z]". Returns true if any title changed.
pub fn updateTabTitles(self: *App) bool {
    var any_changed = false;
    for (self.tab_manager.tabs.items) |*tab| {
        var title_buf: [128]u8 = undefined;
        var offset: usize = 0;

        // Prefer live CWD over tracked CWD: the tracked value only updates on
        // OSC-7, which many shells don't emit, so it can mask `cd` indefinitely.
        if (self.pane_data.get(tab.focused_pane_id)) |pd| {
            var cwd_query_buf: [512]u8 = undefined;
            const cwd_slice: ?[]const u8 = pd.pty.getChildCwd(&cwd_query_buf) orelse blk: {
                const cwd_l = pd.cwd_len.load(.acquire);
                break :blk if (cwd_l > 0) pd.cwd[0..cwd_l] else null;
            };

            const pname_slice: []const u8 = pd.process_name[0..pd.process_name_len];
            const base_slice: ?[]const u8 = if (cwd_slice) |cwd| std.fs.path.basename(cwd) else null;
            const show_process = pname_slice.len > 0 and !isShellName(pname_slice);

            if (show_process) {
                const pn_len = @min(pname_slice.len, title_buf.len - offset);
                @memcpy(title_buf[offset .. offset + pn_len], pname_slice[0..pn_len]);
                offset += pn_len;
                if (base_slice) |base| if (base.len > 0 and offset + 1 < title_buf.len) {
                    title_buf[offset] = '@';
                    offset += 1;
                    const b_len = @min(base.len, title_buf.len - offset);
                    @memcpy(title_buf[offset .. offset + b_len], base[0..b_len]);
                    offset += b_len;
                };
            } else if (base_slice) |base| {
                const b_len = @min(base.len, title_buf.len - offset);
                @memcpy(title_buf[offset .. offset + b_len], base[0..b_len]);
                offset += b_len;
            } else if (pname_slice.len > 0) {
                const pn_len = @min(pname_slice.len, title_buf.len - offset);
                @memcpy(title_buf[offset .. offset + pn_len], pname_slice[0..pn_len]);
                offset += pn_len;
            }
        }

        const pcount = tab.paneCount();
        if (pcount > 1) {
            const badge = std.fmt.bufPrint(title_buf[offset..], " [{d}]", .{pcount}) catch "";
            offset += badge.len;
        }

        if (tab.is_zoomed) {
            if (offset + 4 <= title_buf.len) {
                @memcpy(title_buf[offset .. offset + 4], " [Z]");
                offset += 4;
            }
        }

        const new_title = title_buf[0..offset];
        const old_title = tab.title[0..tab.title_len];
        if (!std.mem.eql(u8, new_title, old_title)) {
            tab.setTitle(new_title);
            any_changed = true;
        }
    }
    return any_changed;
}

/// Open the shell picker overlay.
pub fn actionOpenShellPicker(self: *App) void {
    // Get the currently active pane's shell name for marking
    const current_shell_name: []const u8 = if (getFocusedPaneData(self)) |pd|
        pd.process_name[0..pd.process_name_len]
    else
        "";

    // Filter available shells
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

/// Kill current PTY and respawn with a new shell, preserving pane position.
/// Content is lost. Follows destroyPane ordering for teardown, createPane for spawn.
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

    // Fix up internal pointers (Pitfall 1 -- CRITICAL: surface holds raw pointers
    // into termio/window that are invalidated when respawn replaces the structs).
    pd.surface.termio = &pd.termio;
    pd.surface.window = &self.window;

    // Rewire observer callbacks
    pd.termio.terminal.observer.onBell = callbacks.bellCallback;
    pd.termio.terminal.observer.bell_ctx = @ptrCast(pd);
    pd.termio.terminal.observer.onAgentOutput = callbacks.agentOutputCallback;
    pd.termio.terminal.observer.agent_ctx = @ptrCast(pd);

    // Update process name from new shell
    {
        const shell_path_slice = std.mem.span(shell_config.path);
        const base = std.fs.path.basename(shell_path_slice);
        const name = if (std.mem.endsWith(u8, base, ".exe"))
            base[0 .. base.len - 4]
        else
            base;
        const copy_len = @min(name.len, pd.process_name.len);
        @memset(&pd.process_name, 0);
        @memcpy(pd.process_name[0..copy_len], name[0..copy_len]);
        pd.process_name_len = @intCast(copy_len);
    }

    // Reset transient pane state
    pd.scroll_offset = 0;
    pd.surface.scroll_offset = 0;
    pd.search_state = .{};
    pd.url_state = .{};
    pd.bell_state = .{};
    pd.agent_state = .{};
    pd.last_output_ns = std.atomic.Value(i64).init(0);
    pd.last_process_poll_ns = 0;
    pd.suppress_until_ns = std.atomic.Value(i64).init(0);

    // Wire screen change callback (triggers frame request on terminal output)
    pd.termio.terminal.observer.onScreenChange = &callbacks.screenChangeCallback;
    pd.termio.terminal.observer.screen_change_ctx = @ptrCast(pd);

    // Start TermIO reader thread (must happen after attachPty and observer wiring)
    try pd.termio.start();

    std.log.info("Shell switched to '{s}' in pane {d}", .{ shell_name, pd.pane_id });
}

/// Activate a layout preset: create new tabs with the preset's pane tree.
/// Non-destructive: opens in new tab(s), preserving existing tabs.
pub fn activatePreset(self: *App, preset: *const LayoutPreset.LayoutPreset) void {
    // Hold pane_mutex across structural mutations so the render thread
    // doesn't walk freed tab trees or observe half-built pane_data entries.
    // Must wrap tree replacement, pane creation, and the initial resize —
    // release before blocking on startup-command writes (those can back up
    // on the TermIO writer if the child hasn't read yet).
    self.pane_mutex.lock();

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

    // Resize PTYs for EVERY newly-created tab's panes — not just the active
    // one. A layout with multiple tabs was spawning panes at full-window
    // PTY dims and never resizing until the user switched to that tab.
    if (first_new_tab_idx) |first_idx| {
        const original_active = self.tab_manager.active_idx;
        var ti: usize = first_idx;
        while (ti < self.tab_manager.tabs.items.len) : (ti += 1) {
            self.tab_manager.switchTab(ti);
            resizeAllPanes(self);
        }
        // Leave the first new tab active (original post-activation behavior).
        _ = original_active;
        self.tab_manager.switchTab(first_idx);
    }

    // Release pane_mutex: writes to the PTY can block briefly and the render
    // thread needs to paint.
    self.pane_mutex.unlock();

    // Execute startup commands now that every pane PTY is sized correctly.
    for (preset.tabs, 0..) |tab_def, tab_i| {
        const target_idx = (first_new_tab_idx orelse 0) + tab_i;
        if (target_idx >= self.tab_manager.tabs.items.len) break;
        const tab = &self.tab_manager.tabs.items[target_idx];
        const leaves = tree_ops.collectLeaves(tab.root, self.allocator) catch continue;
        defer self.allocator.free(leaves);
        for (leaves, 0..) |pid, i| {
            if (i >= tab_def.panes.len) break;
            const cmd = tab_def.panes[i].cmd orelse continue;
            if (self.pane_data.get(pid)) |pd| {
                pd.termio.writeInput(cmd) catch {};
                pd.termio.writeInput("\n") catch {};
            }
        }
    }
    _ = updateTabTitles(self);
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

/// Run search matching for a pane's current query against scrollback history + visible screen.
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

    // --- Extract scrollback (history) lines from ghostty-vt PageList ---
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
