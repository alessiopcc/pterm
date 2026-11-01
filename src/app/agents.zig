/// Agent overview glue: builds the agent list for the sidebar and board,
/// decides sidebar visibility, and handles their keys and clicks.
const std = @import("std");
const pio = @import("pio");
const glfw = @import("zglfw");
const app_mod = @import("App.zig");
const App = app_mod.App;
const PaneData = app_mod.PaneData;
const layout_mod = @import("layout");
const tree_ops = layout_mod.tree_ops;
const Rect = layout_mod.Rect.Rect;
const TabBarRenderer = layout_mod.TabBarRenderer.TabBarRenderer;
const StatusBarRenderer = @import("status_bar_renderer").StatusBarRenderer;
const process_monitor = @import("process_monitor");
const overview = @import("agent_overview");
const actions = @import("actions.zig");

pub const Entry = overview.Entry;

/// Whether a pane belongs in the overview: an agent process is running, it
/// has live status reports, or it holds something unread (needs you, done,
/// error). Once an agent exits and its outcome is seen, the pane drops out.
fn isAgentPane(self: *App, pd: *PaneData) bool {
    if (pd.agent_state.hasReports()) return true;
    switch (pd.agent_state.state.load(.acquire)) {
        .waiting, .done, .errored => return true,
        .idle, .working => {},
    }
    _ = self;
    return pd.agent_present.load(.acquire);
}

/// Snapshot every agent pane, in tab / pane order. Strings live in `alloc`.
/// `preview_lines` > 0 also captures the last non-empty screen lines (board).
/// Caller must hold `pane_mutex` when not on the main thread.
pub fn collectEntries(self: *App, alloc: std.mem.Allocator, preview_lines: usize) []Entry {
    var list: std.ArrayList(Entry) = .empty;
    for (self.tab_manager.tabs.items, 0..) |*tab, ti| {
        const leaves = tree_ops.collectLeaves(tab.root, alloc) catch continue;
        for (leaves) |pid| {
            const pd = self.pane_data.get(pid) orelse continue;
            if (!isAgentPane(self, pd)) continue;
            const st = &pd.agent_state;

            const msg_buf = alloc.alloc(u8, @TypeOf(st.*).MAX_MESSAGE) catch continue;
            const message = st.getMessage(msg_buf);
            var app_buf: [64]u8 = undefined;
            const app = st.getApp(&app_buf);
            const proc = pd.process_name[0..pd.process_name_len];
            const name_src = if (app.len > 0) app else if (proc.len > 0) proc else "agent";
            const name = alloc.dupe(u8, name_src) catch continue;

            var folder_buf: [256]u8 = undefined;
            const folder = displayFolder(alloc, pd.currentFolder(&folder_buf), self.home_dir);

            list.append(alloc, .{
                .pane_id = pid,
                .folder = folder,
                .tab_index = ti,
                .state = st.state.load(.acquire),
                .since_ns = st.since_ns.load(.acquire),
                .name = name,
                .message = message,
                .preview = if (preview_lines > 0) capturePreview(pd, alloc, preview_lines) else &.{},
                .focused = ti == self.tab_manager.active_idx and pid == tab.focused_pane_id,
            }) catch break;
        }
    }
    return list.toOwnedSlice(alloc) catch &.{};
}

/// Display form of a folder: no trailing separator, home as "~", "/" separators.
pub fn displayFolder(alloc: std.mem.Allocator, path_in: []const u8, home: []const u8) []const u8 {
    var path = path_in;
    while (path.len > 1 and (path[path.len - 1] == '/' or path[path.len - 1] == '\\')) path = path[0 .. path.len - 1];
    if (path.len == 0) return "";
    const under_home = home.len > 0 and path.len >= home.len and
        std.ascii.eqlIgnoreCase(path[0..home.len], home) and
        (path.len == home.len or path[home.len] == '/' or path[home.len] == '\\');
    const out = (if (under_home)
        std.mem.concat(alloc, u8, &.{ "~", path[home.len..] })
    else
        alloc.dupe(u8, path)) catch return "";
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

/// Last `n` non-empty lines of the pane's screen, trimmed.
fn capturePreview(pd: *PaneData, alloc: std.mem.Allocator, n: usize) []const []const u8 {
    const snap = pd.termio.lockTerminal();
    const term = @constCast(snap);
    const text = term.getScreenText() catch {
        pd.termio.unlockTerminal();
        return &.{};
    };
    pd.termio.unlockTerminal();
    defer term.allocator.free(text);

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitBackwardsScalar(u8, text, '\n');
    while (it.next()) |raw| {
        if (lines.items.len == n) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        lines.append(alloc, alloc.dupe(u8, line) catch break) catch break;
    }
    std.mem.reverse([]const u8, lines.items);
    return lines.toOwnedSlice(alloc) catch &.{};
}

/// Colors derived from the active theme.
pub fn colors(self: *App) overview.Colors {
    const p = &self.renderer_palette;
    const lighten = @import("render.zig").lightenColorU32;
    const bg = p.ui_tab_bar_bg.toU32();
    return .{
        .bg = bg,
        .border = p.ui_pane_border.toU32(),
        .fg = p.default_fg.toU32(),
        .dim = lighten(bg, 45),
        .selected_bg = lighten(bg, 12),
        .overlay = 0x000000A0,
        .working = p.ansi_normal[2].toU32(), // green
        .waiting = p.ui_agent_alert.toU32(),
        .done = p.ansi_normal[4].toU32(), // blue
        .errored = p.ansi_normal[1].toU32(), // red
        .idle = lighten(bg, 30),
    };
}

pub fn metrics(self: *App) overview.Metrics {
    return .{ .cell_w = self.chrome_cell_width, .cell_h = self.chrome_cell_height };
}

// ── Sidebar ──────────────────────────────────────────────

fn chromeHeights(self: *App) struct { top: u32, bottom: u32 } {
    const top = TabBarRenderer.computeHeight(self.chrome_cell_height);
    const bottom: u32 = if (self.config.status_bar.visible) StatusBarRenderer.statusBarHeight(self.chrome_cell_height) else 0;
    return .{ .top = top, .bottom = bottom };
}

/// Sidebar width in pixels for a window this wide (capped at half the window).
fn sidebarWidth(self: *App, fb_w: u32) u32 {
    const cols: u32 = if (self.sidebar_collapsed.load(.acquire)) overview.Sidebar.collapsed_cols else self.config.sidebar.width;
    const want: u32 = @intFromFloat(@as(f32, @floatFromInt(cols)) * self.chrome_cell_width);
    return @min(want, fb_w / 2);
}

/// Sidebar rect, or null when hidden.
pub fn sidebarRect(self: *App, fb_w: u32, fb_h: u32) ?Rect {
    if (!self.sidebar_shown.load(.acquire)) return null;
    const ch = chromeHeights(self);
    const w = sidebarWidth(self, fb_w);
    const h = if (fb_h > ch.top + ch.bottom) fb_h - ch.top - ch.bottom else 0;
    const x: i32 = if (self.config.sidebar.side == .left) 0 else @intCast(fb_w - w);
    return .{ .x = x, .y = @intCast(ch.top), .w = w, .h = h };
}

/// Pane area: window minus tab bar, status bar and sidebar.
pub fn contentRectFor(self: *App, fb_w: u32, fb_h: u32) Rect {
    const ch = chromeHeights(self);
    const h = if (fb_h > ch.top + ch.bottom) fb_h - ch.top - ch.bottom else 0;
    var r: Rect = .{ .x = 0, .y = @intCast(ch.top), .w = fb_w, .h = h };
    if (sidebarRect(self, fb_w, fb_h)) |sb| {
        r.w -= sb.w;
        if (self.config.sidebar.side == .left) r.x = @intCast(sb.w);
    }
    return r;
}

/// Main thread: show/hide the sidebar per config (auto = any agent pane) or
/// the user's toggle; resize panes when it changes.
/// Auto mode waits this long without agents before hiding the sidebar, so
/// brief gaps (agent restarting, process churn) don't make it flap.
const auto_hide_delay_ms: i64 = 3000;

pub fn updateSidebarVisibility(self: *App) void {
    const want = self.sidebar_user orelse switch (self.config.sidebar.visible) {
        .always => true,
        .never => false,
        .auto => blk: {
            const now_ms = pio.milliTimestamp();
            var it = self.pane_data.valueIterator();
            while (it.next()) |pd| {
                if (isAgentPane(self, pd.*)) {
                    self.sidebar_last_agent_ms = now_ms;
                    break :blk true;
                }
            }
            // Keep showing for a while after the last agent disappears.
            break :blk self.sidebar_shown.load(.acquire) and now_ms - self.sidebar_last_agent_ms < auto_hide_delay_ms;
        },
    };
    if (want == self.sidebar_shown.load(.acquire)) return;
    self.sidebar_shown.store(want, .release);
    actions.resizeAllPanes(self);
    self.requestFrame();
}

/// Ctrl+Alt+S: collapse / expand the sidebar (showing it if it is hidden).
pub fn toggleSidebar(self: *App) void {
    if (!self.sidebar_shown.load(.acquire)) {
        self.sidebar_user = true;
        self.sidebar_collapsed.store(false, .release);
        updateSidebarVisibility(self);
        return;
    }
    toggleCollapsed(self);
}

fn toggleCollapsed(self: *App) void {
    self.sidebar_collapsed.store(!self.sidebar_collapsed.load(.acquire), .release);
    actions.resizeAllPanes(self);
    self.requestFrame();
}

// ── Board ────────────────────────────────────────────────

pub fn toggleBoard(self: *App) void {
    const show = !self.board_visible.load(.acquire);
    self.board_visible.store(show, .release);
    if (show) self.board_sel = .{};
    self.requestFrame();
}

/// Switch to the pane's tab and focus it (leaving agent focus mode).
pub fn focusPane(self: *App, pane_id: u32) void {
    if (self.tab_manager.agent_mode_active) actions.exitAgentMode(self);
    for (self.tab_manager.tabs.items, 0..) |*tab, ti| {
        if (tree_ops.findLeaf(tab.root, pane_id) == null) continue;
        if (ti != self.tab_manager.active_idx) self.switchToTab(ti);
        if (self.tab_manager.getActiveTab()) |t| t.focused_pane_id = pane_id;
        break;
    }
    self.requestFrame();
}

/// Board keyboard handling. Returns true if the key was consumed (all keys
/// are while the board is open).
pub fn handleBoardKey(self: *App, key: glfw.Key) bool {
    if (!self.board_visible.load(.acquire)) return false;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const entries = collectEntries(self, arena.allocator(), 0);
    const Board = overview.Board;
    switch (key) {
        .escape => self.board_visible.store(false, .release),
        .up, .k => self.board_sel = Board.move(self.board_sel, .up, entries),
        .down, .j => self.board_sel = Board.move(self.board_sel, .down, entries),
        .left, .h => self.board_sel = Board.move(self.board_sel, .left, entries),
        .right, .l => self.board_sel = Board.move(self.board_sel, .right, entries),
        .enter, .kp_enter => {
            if (Board.selected(self.board_sel, entries)) |i| {
                self.board_visible.store(false, .release);
                focusPane(self, entries[i].pane_id);
            }
        },
        else => {},
    }
    self.requestFrame();
    return true;
}

/// Click handling for board and sidebar. Returns true if consumed.
pub fn handleClick(self: *App, fb_w: u32, fb_h: u32, x: i32, y: i32) bool {
    const board_open = self.board_visible.load(.acquire);
    const sidebar = sidebarRect(self, fb_w, fb_h);
    if (!board_open and sidebar == null) return false;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    if (board_open) {
        // Board cards include previews; layout must match the rendered one.
        const entries = collectEntries(self, arena.allocator(), board_preview_lines);
        if (overview.Board.hitTest(entries, fb_w, fb_h, metrics(self), x, y)) |i| {
            self.board_visible.store(false, .release);
            focusPane(self, entries[i].pane_id);
        } else {
            const p = overview.Board.panel(fb_w, fb_h, metrics(self));
            const inside = x >= p.x and x < p.x + @as(i32, @intCast(p.w)) and y >= p.y and y < p.y + @as(i32, @intCast(p.h));
            if (!inside) self.board_visible.store(false, .release);
        }
        self.requestFrame();
        return true;
    }

    const sb = sidebar.?;
    if (x < sb.x or x >= sb.x + @as(i32, @intCast(sb.w)) or y < sb.y or y >= sb.y + @as(i32, @intCast(sb.h))) return false;
    const entries = collectEntries(self, arena.allocator(), 0);
    const collapsed = self.sidebar_collapsed.load(.acquire);
    if (overview.Sidebar.hitTest(entries, toOverviewRect(sb), metrics(self), collapsed, x, y)) |hit| switch (hit) {
        .toggle => toggleCollapsed(self),
        .pane => |pane_id| focusPane(self, pane_id),
    };
    return true;
}

/// Screen lines shown on each board card.
pub const board_preview_lines = 2;

pub fn toOverviewRect(r: Rect) overview.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

/// Most urgent agent state among a tab's panes (null = no agent activity).
pub fn tabState(self: *App, tab_root: anytype, alloc: std.mem.Allocator) ?overview.State {
    const leaves = tree_ops.collectLeaves(tab_root, alloc) catch return null;
    var best: ?overview.State = null;
    for (leaves) |pid| {
        const pd = self.pane_data.get(pid) orelse continue;
        const s = pd.agent_state.state.load(.acquire);
        if (s == .idle) continue;
        if (best == null or urgency(s) > urgency(best.?)) best = s;
    }
    return best;
}

fn urgency(s: overview.State) u8 {
    return switch (s) {
        .idle => 0,
        .done => 1,
        .working => 2,
        .errored => 3,
        .waiting => 4,
    };
}
