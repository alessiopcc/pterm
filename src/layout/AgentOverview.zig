/// Agent overview UI: a sidebar listing every agent pane grouped by state, and
/// a full-window board with Needs you / Working / Done columns.
///
/// Pure layout + callback-based drawing (same pattern as StatusBarRenderer),
/// so it is testable without a GPU. Render and hit testing share one layout
/// function, so clicks always land on what was drawn.
const std = @import("std");
const AgentState = @import("agent_state").AgentState;

pub const State = AgentState.State;
pub const ColorU32 = u32;

/// One agent pane, snapshotted by the render thread each frame.
pub const Entry = struct {
    pane_id: u32,
    tab_index: usize,
    state: State,
    /// Monotonic ns when the state started (0 = unknown).
    since_ns: i64,
    /// Display name, e.g. "claude" or the reporting app.
    name: []const u8,
    /// Status message ("" if none).
    message: []const u8,
    /// Working folder, display form (e.g. "~/project/pterm"; "" if unknown).
    folder: []const u8 = "",
    /// Last non-empty screen lines (board cards only).
    preview: []const []const u8 = &.{},
    /// The pane currently focused in the active tab.
    focused: bool = false,
};

pub const Colors = struct {
    bg: ColorU32,
    border: ColorU32,
    fg: ColorU32,
    dim: ColorU32,
    selected_bg: ColorU32,
    overlay: ColorU32,
    working: ColorU32,
    waiting: ColorU32,
    done: ColorU32,
    errored: ColorU32,
    idle: ColorU32,

    pub fn forState(self: Colors, state: State) ColorU32 {
        return switch (state) {
            .working => self.working,
            .waiting => self.waiting,
            .done => self.done,
            .errored => self.errored,
            .idle => self.idle,
        };
    }
};

pub const Rect = struct { x: i32, y: i32, w: u32, h: u32 };

pub const DrawRectFn = *const fn (x: i32, y: i32, w: u32, h: u32, color: ColorU32, ctx: *anyopaque) void;
pub const DrawTextFn = *const fn (text: []const u8, x: i32, y: i32, color: ColorU32, ctx: *anyopaque) void;

pub const Metrics = struct { cell_w: f32, cell_h: f32 };

/// Sidebar / board grouping. Errors sit with "needs you".
pub const Group = enum {
    needs_you,
    working,
    done,
    idle,

    pub fn of(state: State) Group {
        return switch (state) {
            .waiting, .errored => .needs_you,
            .working => .working,
            .done => .done,
            .idle => .idle,
        };
    }

    pub fn label(self: Group) []const u8 {
        return switch (self) {
            .needs_you => "NEEDS YOU",
            .working => "WORKING",
            .done => "DONE",
            .idle => "IDLE",
        };
    }
};

// ── Text helpers ─────────────────────────────────────────

/// Longest prefix of `text` that fits in `max_cols` codepoints (one column
/// each), cut on a codepoint boundary.
pub fn fitText(text: []const u8, max_cols: usize) []const u8 {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (cols == max_cols) return text[0..i];
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + len > text.len) return text[0..i];
        i += len;
        cols += 1;
    }
    return text;
}

/// Longest suffix of `text` that fits in `max_cols` columns, prefixed with
/// "…" when cut (paths: the end is the informative part).
pub fn fitTail(text: []const u8, max_cols: usize) []const u8 {
    const cols = textCols(text);
    if (cols <= max_cols) return text;
    if (max_cols < 2) return fitText(text, max_cols);
    // Skip codepoints from the front until the rest fits in max_cols - 1.
    var skip = cols - (max_cols - 1);
    var i: usize = 0;
    while (skip > 0 and i < text.len) : (skip -= 1) {
        i += std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
    }
    return text[@min(i, text.len)..];
}

/// Draw `text` cut to `max_cols` from the front, with "…" when cut.
fn drawTail(draw_text: DrawTextFn, text: []const u8, max_cols: usize, x: i32, y: i32, color: ColorU32, m: Metrics, ctx: *anyopaque) void {
    const tail = fitTail(text, max_cols);
    if (tail.len == text.len) return draw_text(text, x, y, color, ctx);
    draw_text("…", x, y, color, ctx);
    draw_text(tail, x + px(1, m), y, color, ctx);
}

/// Number of codepoints (columns) in `text`.
pub fn textCols(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// "12s", "4m", "3h", "2d"; "" when unknown.
pub fn formatElapsed(buf: []u8, since_ns: i64, now_ns: i64) []const u8 {
    if (since_ns <= 0 or now_ns < since_ns) return "";
    const s: i64 = @divFloor(now_ns - since_ns, std.time.ns_per_s);
    return (if (s < 60)
        std.fmt.bufPrint(buf, "{d}s", .{s})
    else if (s < 3600)
        std.fmt.bufPrint(buf, "{d}m", .{@divFloor(s, 60)})
    else if (s < 86400)
        std.fmt.bufPrint(buf, "{d}h", .{@divFloor(s, 3600)})
    else
        std.fmt.bufPrint(buf, "{d}d", .{@divFloor(s, 86400)})) catch "";
}

fn colsFor(width_px: u32, m: Metrics) usize {
    if (m.cell_w <= 0) return 0;
    return @intFromFloat(@max(0, @as(f32, @floatFromInt(width_px)) / m.cell_w));
}

fn px(cols: usize, m: Metrics) i32 {
    return @intFromFloat(@as(f32, @floatFromInt(cols)) * m.cell_w);
}

fn lineH(m: Metrics) i32 {
    return @intFromFloat(@ceil(m.cell_h));
}

// ── Sidebar ──────────────────────────────────────────────

pub const Sidebar = struct {
    /// Width in columns when collapsed (one state dot per agent).
    pub const collapsed_cols = 3;

    pub const Item = struct {
        kind: enum { title, header, row },
        group: Group = .idle,
        /// Entry index for rows; group count for headers.
        index: usize = 0,
        y: i32,
        h: i32,
    };

    pub const Hit = union(enum) {
        /// The collapse / expand button.
        toggle,
        pane: u32,
    };

    fn rowLines(e: Entry) i32 {
        return 1 + @as(i32, @intFromBool(e.folder.len > 0)) + @as(i32, @intFromBool(e.message.len > 0));
    }

    /// Lay out the title row, then headers and rows top to bottom. Groups with
    /// no entries are skipped.
    /// Collapsed: title row, then one line per entry (group order).
    pub fn layout(entries: []const Entry, rect: Rect, m: Metrics, collapsed: bool, out: []Item) usize {
        const lh = lineH(m);
        const bottom: i32 = rect.y + @as(i32, @intCast(rect.h));
        var n: usize = 0;
        var y: i32 = rect.y + @divFloor(lh, 2);
        if (out.len == 0 or y + lh > bottom) return 0;
        out[0] = .{ .kind = .title, .y = y, .h = lh };
        n = 1;
        y += lh + @divFloor(lh, 2);

        for (std.enums.values(Group)) |g| {
            if (collapsed) {
                for (entries, 0..) |e, i| {
                    if (Group.of(e.state) != g) continue;
                    if (n == out.len or y + lh > bottom) return n;
                    out[n] = .{ .kind = .row, .group = g, .index = i, .y = y, .h = lh };
                    n += 1;
                    y += lh;
                }
                continue;
            }
            var count: usize = 0;
            for (entries) |e| {
                if (Group.of(e.state) == g) count += 1;
            }
            if (count == 0) continue;
            if (n == out.len or y + lh > bottom) return n;
            out[n] = .{ .kind = .header, .group = g, .index = count, .y = y, .h = lh };
            n += 1;
            y += lh;
            for (entries, 0..) |e, i| {
                if (Group.of(e.state) != g) continue;
                const h = rowLines(e) * lh + @divFloor(lh, 3);
                if (n == out.len or y + h > bottom) return n;
                out[n] = .{ .kind = .row, .group = g, .index = i, .y = y, .h = h };
                n += 1;
                y += h;
            }
            y += @divFloor(lh, 2);
        }
        return n;
    }

    pub fn render(
        entries: []const Entry,
        rect: Rect,
        m: Metrics,
        colors: Colors,
        now_ns: i64,
        side_left: bool,
        collapsed: bool,
        draw_rect: DrawRectFn,
        draw_text: DrawTextFn,
        ctx: *anyopaque,
    ) void {
        draw_rect(rect.x, rect.y, rect.w, rect.h, colors.bg, ctx);
        const border_x: i32 = if (side_left) rect.x + @as(i32, @intCast(rect.w)) - 1 else rect.x;
        draw_rect(border_x, rect.y, 1, rect.h, colors.border, ctx);

        var items: [128]Item = undefined;
        const n = layout(entries, rect, m, collapsed, &items);
        const lh = lineH(m);
        const total_cols = colsFor(rect.w, m);

        if (collapsed) {
            // Centered expand chevron, then one state dot per agent.
            const center = rect.x + @divFloor(@as(i32, @intCast(rect.w)), 2);
            const expand = if (side_left) "»" else "«";
            for (items[0..n]) |it| switch (it.kind) {
                .title => draw_text(expand, center - @divFloor(px(1, m), 2), it.y, colors.dim, ctx),
                .header => {},
                .row => {
                    const e = entries[it.index];
                    if (e.focused) draw_rect(rect.x, it.y, rect.w, @intCast(it.h), colors.selected_bg, ctx);
                    const dot: u32 = @intFromFloat(@max(4, m.cell_h * 0.4));
                    const half: i32 = @divFloor(@as(i32, @intCast(dot)), 2);
                    draw_rect(center - half, it.y + @divFloor(lh, 2) - half, dot, dot, colors.forState(e.state), ctx);
                },
            };
            return;
        }

        const pad_cols: usize = 1;
        const inner_cols = if (total_cols > 2 * pad_cols) total_cols - 2 * pad_cols else 0;
        const x0 = rect.x + px(pad_cols, m);

        for (items[0..n]) |it| switch (it.kind) {
            .title => {
                draw_text(fitText("AGENTS", inner_cols), x0, it.y, colors.dim, ctx);
                const collapse = if (side_left) "«" else "»";
                if (inner_cols > 8) draw_text(collapse, x0 + px(inner_cols - 1, m), it.y, colors.dim, ctx);
            },
            .header => {
                var buf: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{s} {d}", .{ it.group.label(), it.index }) catch it.group.label();
                const color = switch (it.group) {
                    .needs_you => colors.waiting,
                    .working => colors.working,
                    .done => colors.done,
                    .idle => colors.dim,
                };
                draw_text(fitText(text, inner_cols), x0, it.y, color, ctx);
            },
            .row => {
                const e = entries[it.index];
                if (e.focused) draw_rect(rect.x, it.y, rect.w, @intCast(it.h), colors.selected_bg, ctx);

                // State dot
                const dot: u32 = @intFromFloat(@max(4, m.cell_h * 0.35));
                const dot_y = it.y + @divFloor(lh - @as(i32, @intCast(dot)), 2);
                draw_rect(x0, dot_y, dot, dot, colors.forState(e.state), ctx);

                // "Tab N · name" + right-aligned elapsed
                var ebuf: [16]u8 = undefined;
                const elapsed = formatElapsed(&ebuf, e.since_ns, now_ns);
                var tbuf: [96]u8 = undefined;
                const title = std.fmt.bufPrint(&tbuf, "Tab {d} · {s}", .{ e.tab_index + 1, e.name }) catch e.name;
                const text_cols = if (inner_cols > 2) inner_cols - 2 else 0;
                const title_cols = if (text_cols > elapsed.len + 1) text_cols - elapsed.len - 1 else text_cols;
                draw_text(fitText(title, title_cols), x0 + px(2, m), it.y, colors.fg, ctx);
                if (elapsed.len > 0 and text_cols > elapsed.len) {
                    draw_text(elapsed, x0 + px(2 + text_cols - elapsed.len, m), it.y, colors.dim, ctx);
                }
                var line_y = it.y + lh;
                if (e.folder.len > 0) {
                    drawTail(draw_text, e.folder, text_cols, x0 + px(2, m), line_y, colors.dim, m, ctx);
                    line_y += lh;
                }
                if (e.message.len > 0) {
                    const msg_color = if (e.state == .errored) colors.errored else colors.fg;
                    draw_text(fitText(e.message, text_cols), x0 + px(2, m), line_y, msg_color, ctx);
                }
            },
        };

        if (entries.len == 0 and n > 0) {
            draw_text(fitText("No agents", inner_cols), x0, items[0].y + 2 * lh, colors.dim, ctx);
        }
    }

    /// What is at (x, y): the collapse/expand toggle, an agent row, or nothing.
    pub fn hitTest(entries: []const Entry, rect: Rect, m: Metrics, collapsed: bool, x: i32, y: i32) ?Hit {
        if (x < rect.x or x >= rect.x + @as(i32, @intCast(rect.w))) return null;
        var items: [128]Item = undefined;
        const n = layout(entries, rect, m, collapsed, &items);
        for (items[0..n]) |it| {
            if (y < it.y or y >= it.y + it.h) continue;
            return switch (it.kind) {
                .title => .toggle,
                .row => .{ .pane = entries[it.index].pane_id },
                .header => null,
            };
        }
        return null;
    }
};

// ── Board ────────────────────────────────────────────────

pub const Board = struct {
    pub const columns = [_]Group{ .needs_you, .working, .done };

    pub const Selection = struct { col: usize = 0, row: usize = 0 };

    pub const Card = struct { entry: usize, col: usize, row: usize, rect: Rect };

    /// Panel rect inside the window (margin around it).
    pub fn panel(win_w: u32, win_h: u32, m: Metrics) Rect {
        const margin: u32 = @intFromFloat(@max(16, m.cell_h * 2));
        const w = if (win_w > 2 * margin) win_w - 2 * margin else win_w;
        const h = if (win_h > 2 * margin) win_h - 2 * margin else win_h;
        return .{ .x = @intCast((win_w - w) / 2), .y = @intCast((win_h - h) / 2), .w = w, .h = h };
    }

    fn columnRect(p: Rect, col: usize, m: Metrics) Rect {
        const gap: u32 = @intFromFloat(m.cell_w * 2);
        const inner = if (p.w > 4 * gap) p.w - 4 * gap else p.w;
        const cw: u32 = inner / @as(u32, columns.len);
        const top: u32 = @intFromFloat(m.cell_h * 4.5);
        return .{
            .x = p.x + @as(i32, @intCast(gap + @as(u32, @intCast(col)) * (cw + gap))),
            .y = p.y + @as(i32, @intCast(top)),
            .w = cw,
            .h = if (p.h > top + gap) p.h - top - gap else 0,
        };
    }

    fn cardHeight(e: Entry, m: Metrics) i32 {
        const lines: i32 = 1 + @as(i32, @intFromBool(e.folder.len > 0)) + @as(i32, @intFromBool(e.message.len > 0)) + @as(i32, @intCast(e.preview.len));
        return lines * lineH(m) + @as(i32, @intFromFloat(m.cell_h));
    }

    /// Lay out cards column by column (entries in their given order).
    pub fn layout(entries: []const Entry, p: Rect, m: Metrics, out: []Card) usize {
        var n: usize = 0;
        for (columns, 0..) |g, col| {
            const cr = columnRect(p, col, m);
            var y: i32 = cr.y;
            const bottom = cr.y + @as(i32, @intCast(cr.h));
            var row: usize = 0;
            for (entries, 0..) |e, i| {
                if (Group.of(e.state) != g) continue;
                const h = cardHeight(e, m);
                if (n == out.len or y + h > bottom) break;
                out[n] = .{ .entry = i, .col = col, .row = row, .rect = .{ .x = cr.x, .y = y, .w = cr.w, .h = @intCast(h) } };
                n += 1;
                row += 1;
                y += h + @divFloor(lineH(m), 2);
            }
        }
        return n;
    }

    /// Number of cards in each column.
    pub fn columnCounts(entries: []const Entry) [columns.len]usize {
        var counts: [columns.len]usize = @splat(0);
        for (entries) |e| {
            for (columns, 0..) |g, col| {
                if (Group.of(e.state) == g) counts[col] += 1;
            }
        }
        return counts;
    }

    /// Keep the selection on an existing card (or the first non-empty column).
    pub fn clamp(sel: Selection, entries: []const Entry) Selection {
        const counts = columnCounts(entries);
        var s = sel;
        if (s.col >= columns.len) s.col = 0;
        if (counts[s.col] == 0) {
            for (counts, 0..) |c, col| {
                if (c > 0) {
                    s.col = col;
                    break;
                }
            }
        }
        if (counts[s.col] == 0) return .{};
        if (s.row >= counts[s.col]) s.row = counts[s.col] - 1;
        return s;
    }

    pub const Move = enum { up, down, left, right };

    pub fn move(sel: Selection, dir: Move, entries: []const Entry) Selection {
        const counts = columnCounts(entries);
        var s = clamp(sel, entries);
        switch (dir) {
            .up => s.row -|= 1,
            .down => s.row += 1,
            .left, .right => {
                var col = s.col;
                var tries: usize = 0;
                while (tries < columns.len) : (tries += 1) {
                    col = if (dir == .left) (col + columns.len - 1) % columns.len else (col + 1) % columns.len;
                    if (counts[col] > 0) break;
                }
                s.col = col;
            },
        }
        return clamp(s, entries);
    }

    /// Entry index of the selected card, or null if the board is empty.
    pub fn selected(sel: Selection, entries: []const Entry) ?usize {
        const s = clamp(sel, entries);
        var row: usize = 0;
        for (entries, 0..) |e, i| {
            if (Group.of(e.state) != columns[s.col]) continue;
            if (row == s.row) return i;
            row += 1;
        }
        return null;
    }

    pub fn render(
        entries: []const Entry,
        sel: Selection,
        win_w: u32,
        win_h: u32,
        m: Metrics,
        colors: Colors,
        now_ns: i64,
        draw_rect: DrawRectFn,
        draw_text: DrawTextFn,
        ctx: *anyopaque,
    ) void {
        draw_rect(0, 0, win_w, win_h, colors.overlay, ctx);
        const p = panel(win_w, win_h, m);
        draw_rect(p.x, p.y, p.w, p.h, colors.bg, ctx);
        draw_rect(p.x, p.y, p.w, 1, colors.border, ctx);
        draw_rect(p.x, p.y + @as(i32, @intCast(p.h)) - 1, p.w, 1, colors.border, ctx);

        const lh = lineH(m);
        const title_x = p.x + px(2, m);
        draw_text("Agents", title_x, p.y + lh, colors.fg, ctx);
        const hint = "arrows: move   Enter: open   Esc: close";
        const hint_cols = textCols(hint);
        const p_cols = colsFor(p.w, m);
        if (p_cols > hint_cols + 12) {
            draw_text(hint, p.x + px(p_cols - hint_cols - 2, m), p.y + lh, colors.dim, ctx);
        }

        const counts = columnCounts(entries);
        for (columns, 0..) |g, col| {
            const cr = columnRect(p, col, m);
            var buf: [32]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "{s} {d}", .{ g.label(), counts[col] }) catch g.label();
            const color = switch (g) {
                .needs_you => colors.waiting,
                .working => colors.working,
                .done => colors.done,
                .idle => colors.dim,
            };
            draw_text(fitText(label, colsFor(cr.w, m)), cr.x, cr.y - lh - @divFloor(lh, 2), color, ctx);
        }

        var cards: [96]Card = undefined;
        const n = layout(entries, p, m, &cards);
        const s = clamp(sel, entries);
        for (cards[0..n]) |c| {
            const e = entries[c.entry];
            const is_sel = c.col == s.col and c.row == s.row;
            draw_rect(c.rect.x, c.rect.y, c.rect.w, c.rect.h, if (is_sel) colors.selected_bg else colors.bg, ctx);
            draw_rect(c.rect.x, c.rect.y, 3, c.rect.h, colors.forState(e.state), ctx);
            draw_rect(c.rect.x, c.rect.y + @as(i32, @intCast(c.rect.h)) - 1, c.rect.w, 1, colors.border, ctx);

            const cols = colsFor(c.rect.w, m);
            const inner = if (cols > 4) cols - 4 else 0;
            const x = c.rect.x + px(2, m);
            var y = c.rect.y + @divFloor(lh, 2);

            var ebuf: [16]u8 = undefined;
            const elapsed = formatElapsed(&ebuf, e.since_ns, now_ns);
            var tbuf: [96]u8 = undefined;
            const title = std.fmt.bufPrint(&tbuf, "Tab {d} · {s}", .{ e.tab_index + 1, e.name }) catch e.name;
            const title_cols = if (inner > elapsed.len + 1) inner - elapsed.len - 1 else inner;
            draw_text(fitText(title, title_cols), x, y, colors.fg, ctx);
            if (elapsed.len > 0 and inner > elapsed.len) draw_text(elapsed, x + px(inner - elapsed.len, m), y, colors.dim, ctx);
            y += lh;
            if (e.folder.len > 0) {
                drawTail(draw_text, e.folder, inner, x, y, colors.dim, m, ctx);
                y += lh;
            }
            if (e.message.len > 0) {
                draw_text(fitText(e.message, inner), x, y, if (e.state == .errored) colors.errored else colors.forState(e.state), ctx);
                y += lh;
            }
            for (e.preview) |line| {
                draw_text(fitText(line, inner), x, y, colors.dim, ctx);
                y += lh;
            }
        }

        if (entries.len == 0) {
            draw_text("No agents running", title_x, p.y + 3 * lh, colors.dim, ctx);
        }
    }

    /// Entry index of the card at (x, y), or null.
    pub fn hitTest(entries: []const Entry, win_w: u32, win_h: u32, m: Metrics, x: i32, y: i32) ?usize {
        var cards: [96]Card = undefined;
        const n = layout(entries, panel(win_w, win_h, m), m, &cards);
        for (cards[0..n]) |c| {
            if (x >= c.rect.x and x < c.rect.x + @as(i32, @intCast(c.rect.w)) and
                y >= c.rect.y and y < c.rect.y + @as(i32, @intCast(c.rect.h))) return c.entry;
        }
        return null;
    }
};

// ── Tests ────────────────────────────────────────────────

const testing = std.testing;
const m_test: Metrics = .{ .cell_w = 8, .cell_h = 16 };

fn entry(id: u32, state: State, msg: []const u8) Entry {
    return .{ .pane_id = id, .tab_index = 0, .state = state, .since_ns = 0, .name = "claude", .message = msg };
}

test "fitText cuts on codepoint boundaries" {
    try testing.expectEqualStrings("Tab", fitText("Tab 2", 3));
    try testing.expectEqualStrings("Tab 2 ·", fitText("Tab 2 · claude", 7));
    try testing.expectEqualStrings("abc", fitText("abc", 10));
    try testing.expectEqualStrings("", fitText("abc", 0));
}

test "formatElapsed" {
    var buf: [16]u8 = undefined;
    const s = std.time.ns_per_s;
    try testing.expectEqualStrings("12s", formatElapsed(&buf, 1, 1 + 12 * s));
    try testing.expectEqualStrings("4m", formatElapsed(&buf, 1, 1 + 250 * s));
    try testing.expectEqualStrings("2h", formatElapsed(&buf, 1, 1 + 7300 * s));
    try testing.expectEqualStrings("", formatElapsed(&buf, 0, 100));
}

test "sidebar groups in order: needs you, working, done, idle" {
    const entries = [_]Entry{
        entry(1, .working, ""),
        entry(2, .idle, ""),
        entry(3, .errored, "build failed"),
        entry(4, .done, ""),
        entry(5, .waiting, "Approve edit?"),
    };
    var items: [32]Sidebar.Item = undefined;
    const n = Sidebar.layout(&entries, .{ .x = 0, .y = 0, .w = 256, .h = 2000 }, m_test, false, &items);
    // title + 4 headers + one row per entry (idle rows included)
    try testing.expectEqual(@as(usize, 1 + 4 + 5), n);
    try testing.expect(items[0].kind == .title);
    try testing.expectEqual(Group.needs_you, items[1].group);
    try testing.expectEqual(@as(usize, 2), items[2].index); // errored, input order
    try testing.expectEqual(@as(usize, 4), items[3].index);
    try testing.expectEqual(Group.idle, items[n - 1].group);
    try testing.expect(items[n - 1].kind == .row);
    try testing.expectEqual(@as(usize, 1), items[n - 1].index);
}

test "sidebar hitTest maps rows to pane ids" {
    const entries = [_]Entry{ entry(7, .waiting, "msg"), entry(9, .working, "") };
    const rect: Rect = .{ .x = 0, .y = 100, .w = 256, .h = 800 };
    var items: [8]Sidebar.Item = undefined;
    for ([_]bool{ false, true }) |collapsed| {
        const n = Sidebar.layout(&entries, rect, m_test, collapsed, &items);
        for (items[0..n]) |it| {
            const hit = Sidebar.hitTest(&entries, rect, m_test, collapsed, 10, it.y + 1);
            switch (it.kind) {
                .row => try testing.expectEqual(entries[it.index].pane_id, hit.?.pane),
                .title => try testing.expect(hit.? == .toggle),
                .header => try testing.expect(hit == null),
            }
        }
    }
    try testing.expect(Sidebar.hitTest(&entries, rect, m_test, false, 300, 120) == null); // outside x
}

test "sidebar layout stops at the bottom edge" {
    var entries: [20]Entry = undefined;
    for (&entries, 0..) |*e, i| e.* = entry(@intCast(i), .working, "m");
    var items: [64]Sidebar.Item = undefined;
    const n = Sidebar.layout(&entries, .{ .x = 0, .y = 0, .w = 256, .h = 200 }, m_test, false, &items);
    try testing.expect(n < 21);
    for (items[0..n]) |it| try testing.expect(it.y + it.h <= 200);
}

test "board selection skips empty columns and clamps" {
    const entries = [_]Entry{ entry(1, .waiting, ""), entry(2, .done, ""), entry(3, .done, "") };
    var sel: Board.Selection = .{ .col = 1, .row = 0 }; // working column is empty
    sel = Board.clamp(sel, &entries);
    try testing.expectEqual(@as(usize, 0), sel.col);
    sel = Board.move(sel, .right, &entries); // skips empty working column
    try testing.expectEqual(@as(usize, 2), sel.col);
    sel = Board.move(sel, .down, &entries);
    try testing.expectEqual(@as(usize, 1), sel.row);
    sel = Board.move(sel, .down, &entries); // clamped
    try testing.expectEqual(@as(usize, 1), sel.row);
    try testing.expectEqual(@as(usize, 2), Board.selected(sel, &entries).?);
    sel = Board.move(sel, .right, &entries); // wraps to needs you
    try testing.expectEqual(@as(usize, 0), sel.col);
    try testing.expectEqual(@as(usize, 0), Board.selected(sel, &entries).?);
}

test "board hitTest returns the clicked card's entry" {
    const entries = [_]Entry{ entry(1, .working, "x"), entry(2, .waiting, "") };
    var cards: [8]Board.Card = undefined;
    const p = Board.panel(1200, 800, m_test);
    const n = Board.layout(&entries, p, m_test, &cards);
    try testing.expectEqual(@as(usize, 2), n);
    for (cards[0..n]) |c| {
        const hit = Board.hitTest(&entries, 1200, 800, m_test, c.rect.x + 5, c.rect.y + 5);
        try testing.expectEqual(c.entry, hit.?);
    }
    try testing.expect(Board.hitTest(&entries, 1200, 800, m_test, 2, 2) == null);
}

test "empty board selects nothing" {
    const entries = [_]Entry{entry(1, .idle, "")};
    try testing.expect(Board.selected(.{}, &entries) == null);
}

test "fitTail keeps the end of a path" {
    try testing.expectEqualStrings("~/a/b", fitTail("~/a/b", 10));
    try testing.expectEqualStrings("/open/pterm", fitTail("~/project/open/pterm", 12));
    try testing.expectEqual(@as(usize, 11), textCols(fitTail("~/project/open/pterm", 12)));
}

test "sidebar rows grow with folder and message lines" {
    var e1 = entry(1, .working, "");
    e1.folder = "~/p";
    const e2 = entry(2, .working, "");
    var e3 = entry(3, .working, "msg");
    e3.folder = "~/q";
    const entries = [_]Entry{ e1, e2, e3 };
    var items: [8]Sidebar.Item = undefined;
    const n = Sidebar.layout(&entries, .{ .x = 0, .y = 0, .w = 256, .h = 2000 }, m_test, false, &items);
    var heights: [3]i32 = undefined;
    var k: usize = 0;
    for (items[0..n]) |it| if (it.kind == .row) {
        heights[k] = it.h;
        k += 1;
    };
    try testing.expect(heights[0] > heights[1]);
    try testing.expect(heights[2] > heights[0]);
}
