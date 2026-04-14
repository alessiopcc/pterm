/// Input handling: keyboard, mouse, search overlay, picker overlays.
const builtin = @import("builtin");
const std = @import("std");
const app_mod = @import("App.zig");
const App = app_mod.App;
const PaneData = app_mod.PaneData;
const actions = @import("actions.zig");
const utils = @import("utils.zig");
const glfw = @import("zglfw");
const keybindings = @import("keybindings");
const Surface = @import("surface").Surface;
const layout_mod = @import("layout");
const PaneTree = layout_mod.PaneTree;
const PaneNode = PaneTree.PaneNode;
const tree_ops = layout_mod.tree_ops;
const Rect = layout_mod.Rect.Rect;
const TabBarRenderer = layout_mod.TabBarRenderer.TabBarRenderer;
const status_bar_mod = @import("status_bar_renderer");
const StatusBarRenderer = status_bar_mod.StatusBarRenderer;
const search_mod = @import("search");
const SearchState = search_mod.SearchState.SearchState;
const open_url = @import("open_url");
const shell_mod = @import("shell");

/// Handle key input: route to focused pane's Surface for VT encoding.
pub fn handleKeyInput(self: *App, key: glfw.Key, action: glfw.Action, mods: glfw.Mods) void {
    if (action != .press and action != .repeat) return;

    self.last_mods = utils.glfwModsToModifiers(mods);

    // Clear text selection on any keypress except clipboard keys (Esc or typing deselects)
    if (self.getFocusedPaneData()) |pd| {
        if (pd.surface.selection.range != null) {
            // Don't clear for modifier-only keys or Ctrl+C/V — clipboard handler needs the selection
            const is_modifier = key == .left_shift or key == .right_shift or
                key == .left_control or key == .right_control or
                key == .left_alt or key == .right_alt or
                key == .left_super or key == .right_super;
            const is_clipboard = mods.control and !mods.alt and !mods.super and
                (key == .c or key == .v);
            if (!is_modifier and !is_clipboard) {
                pd.surface.selection.clear();
                self.requestFrame();
                if (key == .escape) return;
            }
        }
    }

    // Reset scrollback viewport on keypress (snap to live terminal)
    if (self.getFocusedPaneData()) |pd| {
        if (pd.scroll_offset > 0) {
            pd.scroll_offset = 0;
            pd.surface.scroll_offset = 0;
            self.requestFrame();
        }
    }

    // Intercept input when shell picker is visible
    if (self.shell_picker.visible) {
        handleShellPickerInput(self, key);
        return;
    }

    // Intercept input when preset picker is visible
    if (self.preset_picker.visible) {
        handlePickerInput(self, key);
        return;
    }

    // Full input capture when search is open
    if (self.getFocusedPaneData()) |pd| {
        if (pd.search_state.is_open) {
            handleSearchKeyInput(self, pd, key, mods);
            return;
        }
    }

    if (self.debug_key_file) |f| {
        var tmp: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&tmp, "[key] code={d} action={d} ctrl={} shift={} alt={}\n", .{
            @intFromEnum(key), @intFromEnum(action), mods.control, mods.shift, mods.alt,
        }) catch "";
        if (line.len > 0) _ = f.write(line) catch 0;
    }

    // Check keybinding map — special keys first, then character keys
    const km = utils.glfwModsToModifiers(mods);

    if (Surface.mapGlfwKeyToSpecial(key)) |special| {
        const combo = keybindings.KeyCombo{
            .key = .{ .special = special },
            .mods = km,
        };

        if (keybindings.isReservedClipboardKey(combo)) {
            if (self.getFocusedPaneData()) |pd| {
                pd.surface.handleClipboardAction(combo);
            }
            return;
        }

        if (self.keybinding_map.get(combo)) |bound_action| {
            actions.dispatchAction(self, bound_action);
            return;
        }
    }

    // Character-based keybindings (ctrl+shift+h, alt+1, etc.)
    if (utils.glfwKeyToChar(key)) |ch| {
        const combo = keybindings.KeyCombo{
            .key = .{ .char = ch },
            .mods = km,
        };

        if (keybindings.isReservedClipboardKey(combo)) {
            if (self.getFocusedPaneData()) |pd| {
                pd.surface.handleClipboardAction(combo);
            }
            return;
        }

        if (self.keybinding_map.get(combo)) |bound_action| {
            actions.dispatchAction(self, bound_action);
            return;
        }
    }

    // Font zoom via GLFW key codes
    if (mods.control and !mods.alt and !mods.super) {
        const zoom_action: ?keybindings.Action = switch (key) {
            .equal, .right_bracket, .kp_add => .increase_font_size,
            .minus, .slash, .kp_subtract => .decrease_font_size,
            .zero, .kp_0 => .reset_font_size,
            else => null,
        };
        if (zoom_action) |za| {
            actions.dispatchAction(self, za);
            return;
        }
    }

    // Fall through to focused pane for VT encoding
    if (self.getFocusedPaneData()) |pd| {
        pd.surface.handleKeyInput(key, action, mods);
    }
}

/// Handle character input: route to focused pane.
pub fn handleCharInput(self: *App, codepoint: u32) void {
    const cp: u21 = if (codepoint <= 0x10FFFF) @intCast(codepoint) else return;

    // When search is open, printable chars go to search query
    if (self.getFocusedPaneData()) |pd| {
        if (pd.search_state.is_open) {
            if (cp >= 0x20 and cp < 0x7F) {
                pd.search_state.addChar(@intCast(cp));
                self.requestFrame();
            }
            return;
        }
    }

    const combo = keybindings.KeyCombo{
        .key = .{ .char = if (cp >= 'A' and cp <= 'Z') cp + 32 else cp },
        .mods = self.last_mods,
    };

    if (keybindings.isReservedClipboardKey(combo)) {
        if (self.getFocusedPaneData()) |pd| {
            pd.surface.handleClipboardAction(combo);
        }
        return;
    }

    if (self.keybinding_map.get(combo)) |bound_action| {
        actions.dispatchAction(self, bound_action);
        return;
    }

    // Fall through to focused pane
    if (self.getFocusedPaneData()) |pd| {
        pd.surface.handleCharInput(codepoint);
    }
}

/// Handle mouse button: hit-test tab bar, pane borders, pane area.
pub fn handleMouseButton(self: *App, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) void {
    // Handle drag release
    if (action == .release and button == .left) {
        if (self.window_resize_active) {
            self.window_resize_active = false;
            self.window_resize_edge = .{};
        }
        if (self.window_drag_active) {
            // If released without moving, treat as a tab click
            if (!self.window_drag_moved) {
                if (self.window_drag_tab_hit) |idx| {
                    self.switchToTab(idx);
                    self.requestFrame();
                }
            }
            self.window_drag_active = false;
            self.window_drag_moved = false;
            self.window_drag_tab_hit = null;
        }
        if (self.border_drag_active) {
            self.border_drag_active = false;
            self.border_drag_branch = null;
            // Snap to cell grid on release
            self.resizeAllPanes();
            self.requestFrame();
        }
        if (self.text_select_pending) {
            // Single click released without drag — no selection
            self.text_select_pending = false;
            self.text_select_pane_id = null;
        }
        if (self.text_select_active) {
            self.text_select_active = false;
            if (self.text_select_pane_id) |pid| {
                if (self.pane_data.get(pid)) |pd| {
                    _ = pd.surface.selection.finish();
                    self.requestFrame();
                }
            }
            self.text_select_pane_id = null;
        }
        return;
    }

    if (action != .press) return;

    // GLFW on Windows reports cursor positions in the same space as the
    // framebuffer (already DPI-scaled). No multiplication needed.
    const pos = self.window.handle.getCursorPos();
    const fb_x: i32 = @intFromFloat(pos[0]);
    const fb_y: i32 = @intFromFloat(pos[1]);
    const win_x = fb_x;
    const win_y = fb_y;
    const metrics = self.font_grid.getMetrics();
    const fb = self.window.getFramebufferSize();

    // Check window edge resize — but NOT on title bar controls
    if (button == .left) {
        const edge = utils.detectWindowEdge(self, win_x, win_y);
        const in_controls = TabBarRenderer.isInControlsArea(fb_x, fb_y, metrics.cell_height, fb.width);
        if (utils.edgeIsAny(edge) and !in_controls) {
            self.window_resize_active = true;
            self.window_resize_edge = edge;
            const wpos = self.window.getPos();
            const wsz = self.window.getSize();
            self.window_resize_start_screen_x = wpos.x + win_x;
            self.window_resize_start_screen_y = wpos.y + win_y;
            self.window_resize_start_win_x = wpos.x;
            self.window_resize_start_win_y = wpos.y;
            self.window_resize_start_win_w = @intCast(wsz.width);
            self.window_resize_start_win_h = @intCast(wsz.height);
            return;
        }
    }

    // Check title bar + tab bar (both rows) — all in framebuffer coords
    const total_h: i32 = @intCast(TabBarRenderer.computeHeight(metrics.cell_height));
    if (fb_y >= 0 and fb_y < total_h) {
        if (button == .middle) {
            const hit = TabBarRenderer.hitTest(fb_x, fb_y, self.tab_manager.tabCount(), metrics.cell_width, metrics.cell_height, fb.width);
            switch (hit) {
                .tab => |_| self.actionCloseTab(),
                else => {},
            }
            return;
        }
        if (button != .left) return;

        const hit = TabBarRenderer.hitTest(
            fb_x,
            fb_y,
            self.tab_manager.tabCount(),
            metrics.cell_width,
            metrics.cell_height,
            fb.width,
        );
        switch (hit) {
            .close_tab => |_| {
                self.actionCloseTab();
            },
            .new_tab => {
                self.actionNewTab();
            },
            .window_minimize => self.window.iconify(),
            .window_maximize => self.window.toggleMaximize(),
            .window_close => self.window.requestClose(),
            else => {
                // Double-click on title bar area -> maximize/restore
                const now = std.time.nanoTimestamp();
                const elapsed_ns = now - self.titlebar_last_click_time;
                self.titlebar_last_click_time = now;
                if (elapsed_ns > 0 and elapsed_ns < 400_000_000) { // 400ms threshold
                    self.window.toggleMaximize();
                    self.titlebar_last_click_time = 0; // Reset to prevent triple-click trigger
                    return;
                }

                // Tab clicks, drag region, empty space — all start a drag.
                // If released without movement, treat as tab click (see release handler).
                self.window_drag_active = true;
                self.window_drag_moved = false;
                self.window_drag_tab_hit = switch (hit) {
                    .tab => |idx| @as(?usize, idx),
                    else => null,
                };
                const wpos = self.window.getPos();
                self.window_drag_screen_x = wpos.x + win_x;
                self.window_drag_screen_y = wpos.y + win_y;
            },
        }
        return;
    }

    // Right-click context-sensitive copy/paste in pane area
    if (button == .right and action == .press) {
        if (self.getFocusedPaneData()) |pd| {
            if (pd.surface.selection.range != null) {
                pd.surface.copySelection(pd.scroll_offset);
                // copySelection already clears selection
            } else {
                pd.surface.pasteFromClipboard();
            }
        }
        return;
    }

    // Middle-click paste in pane area
    if (button == .middle and action == .press) {
        if (self.getFocusedPaneData()) |pd| {
            pd.surface.pasteFromClipboard();
        }
        return;
    }

    if (button != .left) return;

    // Pane bounds are in framebuffer space (fb_x/fb_y already computed above)

    // Check pane border grab zone (within 4px of border)
    const active_tab = self.tab_manager.getActiveTab() orelse return;
    if (findBorderAtPoint(active_tab.root, fb_x, fb_y)) |border_info| {
        self.border_drag_active = true;
        self.border_drag_branch = border_info.branch;
        self.border_drag_is_vertical = border_info.is_vertical;
        self.border_drag_start_pos = if (border_info.is_vertical) pos[0] else pos[1];
        self.border_drag_start_ratio = border_info.branch.branch.ratio;
        return;
    }

    // Ctrl+Click (Cmd+Click macOS) opens hovered URL
    // Only when url.enabled=true
    if (self.config.url.enabled) {
        const is_url_click = if (builtin.os.tag == .macos) mods.super else mods.control;
        if (is_url_click) {
            if (self.getFocusedPaneData()) |pd| {
                if (pd.url_state.getHoveredUrl()) |url| {
                    open_url.openUrl(url);
                    return; // Consume click
                }
            }
        }
    }

    // Check status bar click: focus the corresponding pane
    if (self.config.status_bar.visible) {
        const sb_height = StatusBarRenderer.statusBarHeight(metrics.cell_height);
        const sb_top: i32 = @intCast(if (fb.height > sb_height) fb.height - sb_height else 0);
        if (fb_y >= sb_top) {
            // Build the same pane_number->pane_id mapping used in render
            const leaf_infos = tree_ops.collectLeafInfos(active_tab.root, std.heap.page_allocator) catch &.{};
            defer if (leaf_infos.len > 0) std.heap.page_allocator.free(leaf_infos);

            var sb_pane_infos: [32]status_bar_mod.PaneStatusInfo = undefined;
            var sb_count: usize = 0;
            for (leaf_infos) |li| {
                if (sb_count >= 32) break;
                if (self.pane_data.get(li.pane_id)) |_| {
                    sb_pane_infos[sb_count] = .{
                        .pane_number = @intCast(sb_count + 1),
                        .state = .idle,
                        .is_focused = false,
                    };
                    sb_count += 1;
                }
            }

            if (StatusBarRenderer.hitTest(sb_pane_infos[0..sb_count], fb_x, metrics.cell_height)) |pane_number| {
                // pane_number is 1-indexed, leaf_infos is 0-indexed
                const idx = pane_number - 1;
                if (idx < leaf_infos.len) {
                    active_tab.focused_pane_id = leaf_infos[idx].pane_id;
                    self.requestFrame();
                    return;
                }
            }
        }
    }

    // Check pane area: focus the clicked pane
    const leaves = tree_ops.collectLeaves(active_tab.root, std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(leaves);

    for (leaves) |pane_id| {
        if (tree_ops.findLeaf(active_tab.root, pane_id)) |leaf_node| {
            if (leaf_node.leaf.bounds.contains(fb_x, fb_y)) {
                active_tab.focused_pane_id = pane_id;

                // Start text selection at click position
                // Detect multi-click: double-click = word, triple-click = line
                if (self.pane_data.get(pane_id)) |pd| {
                    const m = self.font_grid.getMetrics();
                    const cw: u32 = @intFromFloat(m.cell_width);
                    const ch: u32 = @intFromFloat(m.cell_height);
                    if (cw > 0 and ch > 0) {
                        const bounds = leaf_node.leaf.bounds;
                        const rel_x = fb_x - bounds.x;
                        const rel_y = fb_y - bounds.y;
                        if (rel_x >= 0 and rel_y >= 0) {
                            const col: u16 = @intCast(@min(@as(u32, @intCast(rel_x)) / cw, 65535));
                            const row: u32 = @as(u32, @intCast(rel_y)) / ch;
                            const cols: u16 = if (cw > 0) @intCast(@as(u32, @intCast(bounds.w)) / cw) else 80;

                            // Multi-click detection (400ms threshold)
                            const now = std.time.nanoTimestamp();
                            const elapsed_ns = now - self.text_select_last_click_time;
                            self.text_select_last_click_time = now;
                            if (elapsed_ns > 0 and elapsed_ns < 400_000_000) {
                                self.text_select_click_count = @min(self.text_select_click_count + 1, 3);
                            } else {
                                self.text_select_click_count = 1;
                            }

                            pd.surface.selection.clear();

                            if (self.text_select_click_count >= 2) {
                                // Double/triple click: select immediately
                                if (self.text_select_click_count >= 3) {
                                    // Line select
                                    pd.surface.selection.begin(row, 0, .line);
                                    pd.surface.selection.update(row, cols);
                                } else {
                                    // Word select: expand to word boundaries
                                    const snapshot = pd.termio.lockTerminal();
                                    const screens = @constCast(snapshot).getScreens();
                                    const screen = screens.active;
                                    const tcols: u16 = @intCast(screen.pages.cols);

                                    // Compute scroll-aware row for screen coordinates
                                    const ws_total_rows = screen.pages.total_rows;
                                    const ws_active_rows = screen.pages.rows;
                                    const ws_history: u32 = if (ws_total_rows > ws_active_rows) @intCast(ws_total_rows - ws_active_rows) else 0;
                                    const ws_offset = @min(pd.scroll_offset, ws_history);
                                    const ws_base: u32 = ws_history - ws_offset;

                                    // Read codepoint at position
                                    const isWordChar = struct {
                                        fn f(cp: u21) bool {
                                            if (cp == 0 or cp == ' ' or cp == '\t') return false;
                                            // Punctuation/delimiters break words
                                            if (cp < 128) {
                                                const c: u8 = @intCast(cp);
                                                return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
                                            }
                                            return true; // Non-ASCII = part of word
                                        }
                                    }.f;

                                    // Helper to get codepoint at screen-adjusted position
                                    const getCpActive = struct {
                                        fn f(scr: anytype, r: u32, c: u16) u21 {
                                            const p = scr.pages.pin(.{ .active = .{
                                                .x = @intCast(c),
                                                .y = @intCast(r),
                                            } }) orelse return 0;
                                            return p.rowAndCell().cell.codepoint();
                                        }
                                    }.f;
                                    const getCpScreen = struct {
                                        fn f(scr: anytype, r: u32, c: u16) u21 {
                                            const p = scr.pages.pin(.{ .screen = .{
                                                .x = @intCast(c),
                                                .y = @intCast(r),
                                            } }) orelse return 0;
                                            return p.rowAndCell().cell.codepoint();
                                        }
                                    }.f;

                                    // Use screen coords when scrolled, active when not
                                    const lookup_row = if (ws_offset > 0) ws_base + row else row;

                                    // Find word start (scan left)
                                    var word_start: u16 = col;
                                    while (word_start > 0 and isWordChar(
                                        if (ws_offset > 0) getCpScreen(screen, lookup_row, word_start -| 1) else getCpActive(screen, lookup_row, word_start -| 1),
                                    )) {
                                        word_start -= 1;
                                    }
                                    // Find word end (scan right)
                                    var word_end: u16 = col;
                                    while (word_end + 1 < tcols and isWordChar(
                                        if (ws_offset > 0) getCpScreen(screen, lookup_row, word_end + 1) else getCpActive(screen, lookup_row, word_end + 1),
                                    )) {
                                        word_end += 1;
                                    }
                                    pd.termio.unlockTerminal();

                                    pd.surface.selection.begin(row, word_start, .word);
                                    pd.surface.selection.update(row, word_end);
                                }

                                self.text_select_active = true;
                                self.text_select_pending = false;
                            } else {
                                // Single click: defer selection until drag
                                self.text_select_pending = true;
                                self.text_select_start_row = row;
                                self.text_select_start_col = col;
                                self.text_select_active = false;
                            }
                            self.text_select_pane_id = pane_id;
                        }
                    }
                }

                self.requestFrame();
                return;
            }
        }
    }
}

/// Handle cursor position for border drag resize and cursor shape.
pub fn handleCursorPos(self: *App, xpos: f64, ypos: f64) void {
    // Window edge resize (frameless window)
    if (self.window_resize_active) {
        const wpos = self.window.getPos();
        const screen_x: i32 = wpos.x + @as(i32, @intFromFloat(xpos));
        const screen_y: i32 = wpos.y + @as(i32, @intFromFloat(ypos));
        const dx = screen_x - self.window_resize_start_screen_x;
        const dy = screen_y - self.window_resize_start_screen_y;
        const e = self.window_resize_edge;

        var new_x = self.window_resize_start_win_x;
        var new_y = self.window_resize_start_win_y;
        var new_w: i32 = @intCast(self.window_resize_start_win_w);
        var new_h: i32 = @intCast(self.window_resize_start_win_h);

        if (e.right) new_w += dx;
        if (e.bottom) new_h += dy;
        if (e.left) {
            new_x += dx;
            new_w -= dx;
        }
        if (e.top) {
            new_y += dy;
            new_h -= dy;
        }

        // Minimum window size
        const min_w: i32 = 200;
        const min_h: i32 = 100;
        if (new_w < min_w) {
            if (e.left) new_x -= min_w - new_w;
            new_w = min_w;
        }
        if (new_h < min_h) {
            if (e.top) new_y -= min_h - new_h;
            new_h = min_h;
        }

        self.window.setPos(new_x, new_y);
        self.window.setSize(new_w, new_h);
        return;
    }

    // Window drag (frameless window)
    // Use screen-absolute coordinates: window_pos + cursor_pos gives screen position.
    // Compare against the screen-absolute position where the drag started.
    if (self.window_drag_active) {
        const wpos = self.window.getPos();
        const screen_x: i32 = wpos.x + @as(i32, @intFromFloat(xpos));
        const screen_y: i32 = wpos.y + @as(i32, @intFromFloat(ypos));
        const dx = screen_x - self.window_drag_screen_x;
        const dy = screen_y - self.window_drag_screen_y;
        // Only move if there's actual movement (distinguishes click from drag)
        if (dx != 0 or dy != 0) {
            self.window_drag_moved = true;
            self.window.setPos(wpos.x + dx, wpos.y + dy);
            self.window_drag_screen_x = screen_x;
            self.window_drag_screen_y = screen_y;
        }
        return;
    }

    if (self.border_drag_active) {
        const branch = self.border_drag_branch orelse return;
        const b = &branch.branch;
        const parent_bounds = getNodeBounds(branch);

        const total_size: f64 = if (self.border_drag_is_vertical)
            @floatFromInt(parent_bounds.w)
        else
            @floatFromInt(parent_bounds.h);

        if (total_size <= 0) return;

        const current_pos: f64 = if (self.border_drag_is_vertical) xpos else ypos;
        const delta_px = current_pos - self.border_drag_start_pos;
        const delta_ratio: f32 = @floatCast(delta_px / total_size);

        var new_ratio = self.border_drag_start_ratio + delta_ratio;
        new_ratio = @max(0.1, @min(0.9, new_ratio));
        b.ratio = new_ratio;

        self.resizeAllPanes();
        self.requestFrame();
        return;
    }

    // Text selection: start selection on first drag movement (single click deferred)
    if (self.text_select_pending) {
        if (self.text_select_pane_id) |pid| {
            if (self.pane_data.get(pid)) |pd| {
                pd.surface.selection.begin(self.text_select_start_row, self.text_select_start_col, .normal);
                self.text_select_active = true;
                self.text_select_pending = false;
            }
        }
    }

    // Text selection drag: update selection endpoint as cursor moves
    if (self.text_select_active) {
        if (self.text_select_pane_id) |pid| {
            if (self.pane_data.get(pid)) |pd| {
                const active_tab_sel = self.tab_manager.getActiveTab();
                if (active_tab_sel) |at| {
                    if (tree_ops.findLeaf(at.root, pid)) |leaf_node| {
                        const m = self.font_grid.getMetrics();
                        const cw: u32 = @intFromFloat(m.cell_width);
                        const ch: u32 = @intFromFloat(m.cell_height);
                        if (cw > 0 and ch > 0) {
                            const bounds = leaf_node.leaf.bounds;
                            const rel_x = @as(i32, @intFromFloat(xpos)) - bounds.x;
                            const rel_y = @as(i32, @intFromFloat(ypos)) - bounds.y;
                            const clamped_x: u32 = if (rel_x < 0) 0 else @intCast(rel_x);
                            const clamped_y: u32 = if (rel_y < 0) 0 else @intCast(rel_y);
                            const col: u16 = @intCast(@min(clamped_x / cw, 65535));
                            const row: u32 = clamped_y / ch;
                            pd.surface.selection.update(row, col);
                            self.requestFrame();
                        }
                    }
                }
            }
        }
        return;
    }

    // GLFW cursor positions are already in framebuffer space on Windows
    const win_x: i32 = @intFromFloat(xpos);
    const win_y: i32 = @intFromFloat(ypos);
    const fb_x = win_x;
    const fb_y = win_y;

    // Track which control button is hovered (for background highlight)
    const cur_metrics = self.font_grid.getMetrics();
    const cur_fb = self.window.getFramebufferSize();
    const old_hover = self.hovered_control;
    if (TabBarRenderer.isInControlsArea(fb_x, fb_y, cur_metrics.cell_height, cur_fb.width)) {
        const hit = TabBarRenderer.hitTest(fb_x, fb_y, 0, cur_metrics.cell_width, cur_metrics.cell_height, cur_fb.width);
        self.hovered_control = switch (hit) {
            .window_minimize => 1,
            .window_maximize => 2,
            .window_close => 3,
            else => 0,
        };
    } else {
        self.hovered_control = 0;
    }
    if (self.hovered_control != old_hover) self.requestFrame();

    // Window edge cursor shape (frameless window resize)
    const edge = utils.detectWindowEdge(self, win_x, win_y);
    if (utils.edgeIsAny(edge)) {
        const shape: glfw.Cursor.Shape = blk: {
            if ((edge.left and edge.top) or (edge.right and edge.bottom)) break :blk .resize_nwse;
            if ((edge.right and edge.top) or (edge.left and edge.bottom)) break :blk .resize_nesw;
            if (edge.left or edge.right) break :blk .resize_ew;
            break :blk .resize_ns;
        };
        if (glfw.Cursor.createStandard(shape)) |cursor| {
            self.window.handle.setCursor(cursor);
        } else |_| {}
        return;
    }

    // Pane border cursor shape (pane bounds are in framebuffer space)
    const active_tab = self.tab_manager.getActiveTab() orelse return;
    if (findBorderAtPoint(active_tab.root, fb_x, fb_y)) |border_info| {
        const shape: glfw.Cursor.Shape = if (border_info.is_vertical) .resize_ew else .resize_ns;
        if (glfw.Cursor.createStandard(shape)) |cursor| {
            self.window.handle.setCursor(cursor);
        } else |_| {}
    } else {
        // URL hover detection + pointing hand cursor
        if (self.config.url.enabled) {
            if (self.getFocusedPaneData()) |pd| {
                // Convert pixel position to cell coordinates
                const cur_m = self.font_grid.getMetrics();
                const active_t = self.tab_manager.getActiveTab();
                if (active_t) |at| {
                    if (tree_ops.findLeaf(at.root, at.focused_pane_id)) |leaf| {
                        const bounds = leaf.leaf.bounds;
                        const rel_x = fb_x - bounds.x;
                        const rel_y = fb_y - bounds.y;
                        const cw_int: u32 = @intFromFloat(cur_m.cell_width);
                        const ch_int: u32 = @intFromFloat(cur_m.cell_height);
                        if (rel_x >= 0 and rel_y >= 0 and cw_int > 0 and ch_int > 0) {
                            const cell_col: u16 = @intCast(@min(@as(u32, @intCast(rel_x)) / cw_int, 65535));
                            const cell_row: u32 = @as(u32, @intCast(rel_y)) / ch_int;

                            // Extract line codepoints for URL string extraction
                            var line_buf: [512]u21 = undefined;
                            var line_slice: ?[]const u21 = null;
                            {
                                const snapshot = pd.termio.lockTerminal();
                                defer pd.termio.unlockTerminal();
                                const screens = @constCast(snapshot).getScreens();
                                const screen = screens.active;
                                const url_cols: u16 = @intCast(screen.pages.cols);
                                var ci: u16 = 0;
                                while (ci < url_cols and ci < 512) : (ci += 1) {
                                    const pin = screen.pages.pin(.{ .active = .{
                                        .x = @intCast(ci),
                                        .y = @intCast(cell_row),
                                    } }) orelse {
                                        line_buf[ci] = ' ';
                                        continue;
                                    };
                                    const rac = pin.rowAndCell();
                                    const cp_val = rac.cell.codepoint();
                                    line_buf[ci] = if (cp_val > 0) cp_val else ' ';
                                }
                                line_slice = line_buf[0..ci];
                            }
                            pd.url_state.updateHoverWithLine(cell_row, cell_col, line_slice);

                            if (pd.url_state.hovered_url != null) {
                                if (!pd.url_state.cursor_is_hand) {
                                    if (self.hand_cursor) |hc| {
                                        self.window.handle.setCursor(hc);
                                    }
                                    pd.url_state.cursor_is_hand = true;
                                }
                                self.requestFrame(); // Redraw underline
                                return;
                            } else if (pd.url_state.cursor_is_hand) {
                                pd.url_state.cursor_is_hand = false;
                                self.window.handle.setCursor(null);
                                self.requestFrame(); // Remove underline
                                return;
                            }
                        }
                    }
                }
            }
        }
        self.window.handle.setCursor(null); // Default arrow
    }
}

/// Handle key input when search is open. Intercepts all keys.
pub fn handleSearchKeyInput(self: *App, pd: *PaneData, key: glfw.Key, mods: glfw.Mods) void {
    switch (key) {
        .escape => {
            pd.search_state.close();
            self.requestFrame();
        },
        .enter => {
            if (mods.shift) {
                pd.search_state.navigatePrev();
            } else {
                pd.search_state.navigateNext();
            }
            self.requestFrame();
        },
        .backspace => {
            pd.search_state.deleteChar();
            self.requestFrame();
        },
        else => {
            // Ctrl+Shift+F toggles search closed
            if (mods.control and mods.shift) {
                if (utils.glfwKeyToChar(key)) |ch| {
                    if (ch == 'f') {
                        pd.search_state.close();
                        self.requestFrame();
                    }
                }
            }
            // Printable chars handled via charCallback (handleCharInput)
        },
    }
}

/// Handle keyboard input while the preset picker overlay is visible.
pub fn handlePickerInput(self: *App, key: glfw.Key) void {
    switch (key) {
        .up => {
            self.preset_picker.moveUp();
            self.requestFrame();
        },
        .down => {
            self.preset_picker.moveDown();
            self.requestFrame();
        },
        .enter, .kp_enter => {
            const idx = self.preset_picker.getSelectedIndex();
            if (idx < self.config.layouts.len) {
                self.activatePreset(&self.config.layouts[idx]);
            }
            self.preset_picker.close();
            self.requestFrame();
        },
        .escape => {
            self.preset_picker.close();
            self.requestFrame();
        },
        else => {}, // Ignore all other keys while picker is open
    }
}

/// Handle keyboard input while the shell picker overlay is visible.
pub fn handleShellPickerInput(self: *App, key: glfw.Key) void {
    switch (key) {
        .up => {
            self.shell_picker.moveUp();
            self.requestFrame();
        },
        .down => {
            self.shell_picker.moveDown();
            self.requestFrame();
        },
        .enter, .kp_enter => {
            const idx = self.shell_picker.getSelectedIndex();
            if (self.available_shells) |shells| {
                if (idx < shells.len) {
                    const selected = shells[idx];
                    if (self.getFocusedPaneData()) |pd| {
                        self.respawnShell(pd, selected.name) catch |err| {
                            std.log.err("Shell switch failed: {}", .{err});
                        };
                    }
                }
            }
            self.closeShellPicker();
            self.requestFrame();
        },
        .escape => {
            self.closeShellPicker();
            self.requestFrame();
        },
        else => {},
    }
}

/// Border hit-test result.
pub const BorderHit = struct {
    branch: *PaneNode,
    is_vertical: bool, // true = vertical border (left/right resize)
};

/// Find a border within the grab zone (4px) at the given pixel position.
pub fn findBorderAtPoint(node: *PaneNode, x: i32, y: i32) ?BorderHit {
    switch (node.*) {
        .branch => |b| {
            const first_bounds = getNodeBounds(b.first);
            const grab_zone: i32 = 4;

            switch (b.direction) {
                .vertical => {
                    const border_x = first_bounds.x + @as(i32, @intCast(first_bounds.w));
                    if (x >= border_x - grab_zone and x <= border_x + grab_zone) {
                        return .{ .branch = node, .is_vertical = true };
                    }
                },
                .horizontal => {
                    const border_y = first_bounds.y + @as(i32, @intCast(first_bounds.h));
                    if (y >= border_y - grab_zone and y <= border_y + grab_zone) {
                        return .{ .branch = node, .is_vertical = false };
                    }
                },
            }

            // Recurse into children
            return findBorderAtPoint(b.first, x, y) orelse findBorderAtPoint(b.second, x, y);
        },
        .leaf => return null,
    }
}

/// Compute the bounding rect of a PaneNode (leaf bounds or union of children).
fn getNodeBounds(node: *PaneNode) Rect {
    switch (node.*) {
        .leaf => |l| return l.bounds,
        .branch => |b| {
            const fb = getNodeBounds(b.first);
            const sb = getNodeBounds(b.second);
            const min_x = @min(fb.x, sb.x);
            const min_y = @min(fb.y, sb.y);
            const max_x = @max(fb.x + @as(i32, @intCast(fb.w)), sb.x + @as(i32, @intCast(sb.w)));
            const max_y = @max(fb.y + @as(i32, @intCast(fb.h)), sb.y + @as(i32, @intCast(sb.h)));
            return .{
                .x = min_x,
                .y = min_y,
                .w = @intCast(max_x - min_x),
                .h = @intCast(max_y - min_y),
            };
        },
    }
}
