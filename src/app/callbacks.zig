/// GLFW and observer callbacks extracted from App.zig.
///
/// GLFW callbacks use getUserPointer to recover *App from the window handle.
/// Observer callbacks (bellCallback, agentOutputCallback) receive context
/// pointers passed during TermIO setup. screenChangeCallback and
/// configReloadCallback use module-level static vars (one App per process).
const std = @import("std");
const glfw = @import("zglfw");
const app_mod = @import("App.zig");
const App = app_mod.App;
const PaneData = app_mod.PaneData;
const window_mod = @import("window");
const Window = window_mod.Window;
const bell_state_mod = @import("bell_state");
const BellState = bell_state_mod.BellState;
const cli_mod = @import("cli");
const Config = @import("config").Config;
const theme_mod = @import("theme");
const watcher_mod = @import("watcher");
const FileWatcher = watcher_mod.FileWatcher;
const mouse = @import("mouse");
const layout_mod = @import("layout");
const tree_ops = layout_mod.tree_ops;

/// Check if the focused pane's terminal has SGR mouse forwarding active.
/// Must be called without the terminal lock held.
fn isMouseForwardingActive(pd: *PaneData) bool {
    const snapshot = pd.termio.lockTerminal();
    const tracking = @constCast(snapshot).isMouseTrackingEnabled();
    const sgr = @constCast(snapshot).isMouseFormatSgr();
    pd.termio.unlockTerminal();
    return tracking and sgr;
}

/// Write an SGR mouse escape sequence to the focused pane's PTY.
fn sendMouseEvent(pd: *PaneData, event: mouse.MouseEvent) void {
    const sgr = mouse.encodeSgrMouse(event);
    if (sgr.len == 0) return;
    var buf: [35]u8 = undefined; // 3 prefix + 32 max params
    buf[0] = 0x1b;
    buf[1] = '[';
    buf[2] = '<';
    @memcpy(buf[3 .. 3 + sgr.len], sgr.buf[0..sgr.len]);
    pd.termio.writeInput(buf[0 .. 3 + sgr.len]) catch {};
}

/// Convert pixel position to cell coordinates relative to the focused pane.
/// Returns null if outside pane or metrics are zero.
fn pixelToCell(app: *App, fb_x: i32, fb_y: i32) ?struct { col: u16, row: u16 } {
    const active_tab = app.tab_manager.getActiveTab() orelse return null;
    const leaf_node = tree_ops.findLeaf(active_tab.root, active_tab.focused_pane_id) orelse return null;
    const bounds = leaf_node.leaf.bounds;
    if (!bounds.contains(fb_x, fb_y)) return null;
    const m = app.font_grid.getMetrics();
    const cw: u32 = @intFromFloat(m.cell_width);
    const ch: u32 = @intFromFloat(m.cell_height);
    if (cw == 0 or ch == 0) return null;
    const rel_x = fb_x - bounds.x;
    const rel_y = fb_y - bounds.y;
    if (rel_x < 0 or rel_y < 0) return null;
    return .{
        .col = @intCast(@min(@as(u32, @intCast(rel_x)) / cw, 65535)),
        .row = @intCast(@min(@as(u32, @intCast(rel_y)) / ch, 65535)),
    };
}

// Static state for config reload callback (FileWatcher callback has no context pointer).
// Safe because there is exactly one App instance per process.
pub var g_reload_app: ?*App = null;

// Static state for screen change callback (shared across all panes).
pub var g_screen_change_app: ?*App = null;

// -- Static GLFW callbacks --

pub fn keyCallback(handle: *glfw.Window, key: glfw.Key, _: c_int, action: glfw.Action, mods: glfw.Mods) callconv(.c) void {
    const app = Window.getUserPointer(App, handle) orelse return;
    app.handleKeyInput(key, action, mods);
}

pub fn charCallback(handle: *glfw.Window, codepoint: u32) callconv(.c) void {
    const app = Window.getUserPointer(App, handle) orelse return;
    app.handleCharInput(codepoint);
}

pub fn framebufferSizeCallback(handle: *glfw.Window, width: c_int, height: c_int) callconv(.c) void {
    const app = Window.getUserPointer(App, handle) orelse return;
    // Ignore 0x0 (minimized window) — don't store it so restore sees correct old size
    if (width <= 0 or height <= 0) return;
    // Skip if size hasn't actually changed (e.g., restore from minimize)
    // to avoid terminal reflow that repositions cursor to top
    const old_w = app.new_fb_width.load(.acquire);
    const old_h = app.new_fb_height.load(.acquire);
    if (old_w == @as(u32, @intCast(width)) and old_h == @as(u32, @intCast(height))) {
        app.requestFrame(); // Still redraw, just don't resize terminal
        return;
    }
    // Suppress agent state transitions immediately — before any render thread
    // processes the resize and triggers PTY output that would flip state to working
    var pd_iter = app.pane_data.iterator();
    while (pd_iter.next()) |entry| {
        entry.value_ptr.*.suppress_agent_output.store(true, .release);
    }
    app.new_fb_width.store(@intCast(width), .release);
    app.new_fb_height.store(@intCast(height), .release);
    app.pending_resize.store(true, .release);
    app.requestFrame();
}

pub fn contentScaleCallback(handle: *glfw.Window, xscale: f32, _: f32) callconv(.c) void {
    const app = Window.getUserPointer(App, handle) orelse return;
    const scale_fp: u32 = @intFromFloat(xscale * 100.0);
    const old_fp = app.new_dpi_scale.load(.acquire);
    if (scale_fp == old_fp) return;
    app.new_dpi_scale.store(scale_fp, .release);
    app.pending_dpi_change.store(true, .release);
    app.requestFrame();
}

pub fn focusCallback(handle: *glfw.Window, focused: glfw.Bool) callconv(.c) void {
    const app = Window.getUserPointer(App, handle) orelse return;
    app.focused = @intFromEnum(focused) != 0;
    if (app.focused) {
        app.cursor_blink_timer = std.time.nanoTimestamp();
        app.cursor_visible = true;
        // Invalidate row caches to force full redraw after minimize/restore.
        // This avoids triggering pending_resize which would reflow the terminal.
        var pd_iter = app.pane_data.iterator();
        while (pd_iter.next()) |entry| {
            entry.value_ptr.*.row_cache.invalidate();
        }
    }
    app.requestFrame();
}

pub fn scrollCallback(handle: *glfw.Window, _: f64, yoffset: f64) callconv(.c) void {
    const app = Window.getUserPointer(App, handle) orelse return;
    if (yoffset == 0) return;

    if (app.getFocusedPaneData()) |pd| {
        if (isMouseForwardingActive(pd)) {
            const pos = app.window.handle.getCursorPos();
            const fb_x: i32 = @intFromFloat(pos[0]);
            const fb_y: i32 = @intFromFloat(pos[1]);
            if (pixelToCell(app, fb_x, fb_y)) |cell| {
                // Send one scroll event per notch (3 lines worth)
                const notches: u32 = @intFromFloat(@abs(yoffset));
                const btn: mouse.MouseButton = if (yoffset > 0) .scroll_up else .scroll_down;
                for (0..notches) |_| {
                    sendMouseEvent(pd, .{
                        .button = btn,
                        .action = .press,
                        .col = cell.col + 1, // SGR is 1-based
                        .row = cell.row + 1,
                        .modifiers = .{},
                    });
                }
            }
            app.requestFrame();
            return;
        }

        // Normal scrollback behavior
        const lines: i32 = @intFromFloat(yoffset * 3.0);
        if (lines > 0) {
            pd.scroll_offset +|= @intCast(lines);
            const snap2 = pd.termio.lockTerminal();
            const screens = @constCast(snap2).getScreens();
            const screen = screens.active;
            const total_rows = screen.pages.total_rows;
            const active_rows = screen.pages.rows;
            pd.termio.unlockTerminal();
            const max_scroll: u32 = if (total_rows > active_rows) @intCast(total_rows - active_rows) else 0;
            pd.scroll_offset = @min(pd.scroll_offset, max_scroll);
        } else {
            const down: u32 = @intCast(-lines);
            if (down >= pd.scroll_offset) {
                pd.scroll_offset = 0;
            } else {
                pd.scroll_offset -= down;
            }
        }
        pd.surface.scroll_offset = pd.scroll_offset;
    }
    app.requestFrame();
}

pub fn mouseButtonCallback(handle: *glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) callconv(.c) void {
    const app = Window.getUserPointer(App, handle) orelse return;

    if (app.getFocusedPaneData()) |pd| {
        if (isMouseForwardingActive(pd)) {
            const pos = app.window.handle.getCursorPos();
            const fb_x: i32 = @intFromFloat(pos[0]);
            const fb_y: i32 = @intFromFloat(pos[1]);
            if (pixelToCell(app, fb_x, fb_y)) |cell| {
                const btn: mouse.MouseButton = switch (button) {
                    .left => .left,
                    .right => .right,
                    .middle => .middle,
                    else => .none,
                };
                const act: mouse.MouseAction = if (action == .release) .release else .press;
                sendMouseEvent(pd, .{
                    .button = btn,
                    .action = act,
                    .col = cell.col + 1,
                    .row = cell.row + 1,
                    .modifiers = .{
                        .shift = mods.shift,
                        .alt = mods.alt,
                        .ctrl = mods.control,
                    },
                });
                app.requestFrame();
                return; // Don't pass to UI handlers
            }
        }
    }

    app.handleMouseButton(button, action, mods);
}

pub fn cursorPosCallback(handle: *glfw.Window, xpos: f64, ypos: f64) callconv(.c) void {
    const app = Window.getUserPointer(App, handle) orelse return;
    app.handleCursorPos(xpos, ypos);
}

// -- Observer callbacks --

/// Bell callback: invoked from read thread when BEL byte detected in output.
/// Context pointer points to the PaneData's BellState.
pub fn bellCallback(ctx: ?*anyopaque) void {
    if (ctx) |c| {
        const state: *BellState = @ptrCast(@alignCast(c));
        _ = state.trigger();
    }
}

/// Agent output callback: invoked from read thread on every raw output event.
/// Context pointer points to PaneData. Clears waiting state,
/// resets idle timer, and schedules scan for next render snapshot.
pub fn agentOutputCallback(ctx: ?*anyopaque) void {
    if (ctx) |c| {
        const pd: *PaneData = @ptrCast(@alignCast(c));
        // Suppress agent state transitions during resize (PTY redraws cause false positives)
        if (pd.suppress_agent_output.load(.acquire)) {
            pd.idle_tracker.recordOutputNow();
            return;
        }
        pd.agent_state.onOutput();
        pd.idle_tracker.recordOutputNow();
        pd.needs_agent_scan.store(true, .release);
    }
}

/// Per-pane screen change callback.
/// Context pointer is the PaneData that produced output.
/// Only marks that pane's tab as having activity (not all tabs).
pub fn screenChangeCallback(ctx: ?*anyopaque) void {
    if (g_screen_change_app) |app| {
        // Skip activity marking during resize cooldown
        if (app.suppress_activity_frames.load(.acquire) == 0) {
            if (ctx) |raw| {
                const pd: *PaneData = @ptrCast(@alignCast(raw));
                const pane_tab_idx = pd.tab_index;
                const active_idx = app.tab_manager.active_idx;
                if (pane_tab_idx != active_idx and pane_tab_idx < app.tab_manager.tabs.items.len) {
                    app.tab_manager.tabs.items[pane_tab_idx].has_activity = true;
                }
            }
        }
        app.requestFrame();
    }
}

/// Config reload callback: invoked by FileWatcher when config file changes.
pub fn configReloadCallback() void {
    const self = g_reload_app orelse return;
    const cli_args = cli_mod.CliArgs{ .config_path = self.config_path };
    const new_config = Config.load(self.allocator, cli_args) catch |err| {
        std.log.warn("Config reload failed: {}", .{err});
        return;
    };
    self.renderer_palette = theme_mod.buildRendererPaletteFromConfig(new_config.colors, new_config.theme);
    // Update notification manager from new config
    self.notification_manager.updateConfig(
        new_config.agent.notification_cooldown,
        new_config.agent.notifications,
        new_config.agent.suppress_when_focused,
        new_config.agent.notification_sound,
    );
    // Free old config's arena (all heap strings freed at once)
    self.config.deinit();
    self.config = new_config;
    self.requestFrame();
    std.log.info("Config hot-reloaded", .{});
}
