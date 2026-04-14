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
    // Mouse wheel scrollback: scroll 3 lines per notch
    if (yoffset != 0) {
        if (app.getFocusedPaneData()) |pd| {
            const lines: i32 = @intFromFloat(yoffset * 3.0);
            if (lines > 0) {
                // Scroll up (into history)
                pd.scroll_offset +|= @intCast(lines);
                // Clamp to available history
                const snapshot = pd.termio.lockTerminal();
                const screens = @constCast(snapshot).getScreens();
                const screen = screens.active;
                const total_rows = screen.pages.total_rows;
                const active_rows = screen.pages.rows;
                pd.termio.unlockTerminal();
                const max_scroll: u32 = if (total_rows > active_rows) @intCast(total_rows - active_rows) else 0;
                pd.scroll_offset = @min(pd.scroll_offset, max_scroll);
            } else {
                // Scroll down (toward live)
                const down: u32 = @intCast(-lines);
                if (down >= pd.scroll_offset) {
                    pd.scroll_offset = 0;
                } else {
                    pd.scroll_offset -= down;
                }
            }
            pd.surface.scroll_offset = pd.scroll_offset;
        }
    }
    app.requestFrame();
}

pub fn mouseButtonCallback(handle: *glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) callconv(.c) void {
    const app = Window.getUserPointer(App, handle) orelse return;
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
/// Context pointer points to PaneData. Clears waiting state (D-04),
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

/// Per-pane screen change callback (D-13).
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
    // Update notification manager from new config (D-20 hot-reload)
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
