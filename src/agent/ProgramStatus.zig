/// Per-pane table of program status records (OSC 7501, plus OSC 9;4 progress
/// mapped onto a reserved record id).
///
/// A program reports on its root record (id "") and optionally on child
/// records ("session-1", "deploy/us-east"). Each report replaces its record;
/// `clear` removes a record and everything beneath it (no id = everything).
///
/// Lifetime (spec): when the program exits or a new shell prompt starts,
/// working / blocked records are dropped (idle may be); done / error stay.
///
/// The pane shows one state: the most urgent record wins
/// (blocked > error > working > done > idle), most recent first on ties.
///
/// Not thread-safe; the owner (AgentState) serializes access.
const std = @import("std");
const observer = @import("observer");

pub const StatusReport = observer.StatusReport;

pub const State = enum(u8) {
    idle,
    working,
    done,
    blocked,
    errored,

    fn urgency(self: State) u8 {
        return switch (self) {
            .idle => 0,
            .done => 1,
            .working => 2,
            .errored => 3,
            .blocked => 4,
        };
    }

    fn transient(self: State) bool {
        return self == .working or self == .blocked or self == .idle;
    }
};

pub const max_records = 64;
pub const max_id = 128;
pub const max_app = 32;
pub const max_text = 160;

pub const Record = struct {
    id_buf: [max_id]u8 = undefined,
    id_len: u8 = 0,
    state: State = .idle,
    kind: ?StatusReport.Kind = null,
    progress: ?u8 = null,
    app_buf: [max_app]u8 = undefined,
    app_len: u8 = 0,
    title_buf: [max_text]u8 = undefined,
    title_len: u8 = 0,
    msg_buf: [max_text]u8 = undefined,
    msg_len: u8 = 0,
    /// When `state` last changed.
    since_ns: i128 = 0,

    pub fn id(self: *const Record) []const u8 {
        return self.id_buf[0..self.id_len];
    }
    pub fn app(self: *const Record) []const u8 {
        return self.app_buf[0..self.app_len];
    }
    pub fn title(self: *const Record) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    pub fn msg(self: *const Record) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }
};

pub const ProgramStatus = @This();

records: [max_records]Record = undefined,
len: usize = 0,

pub fn isEmpty(self: *const ProgramStatus) bool {
    return self.len == 0;
}

/// Apply one report. Returns true if the table changed.
pub fn apply(self: *ProgramStatus, r: StatusReport, now: i128) bool {
    if (r.id.len > max_id) return false;

    const state: State = switch (r.state) {
        .clear => return self.clear(r.id),
        .idle => .idle,
        .working => .working,
        .done => .done,
        .blocked => .blocked,
        .err => .errored,
    };

    const rec = self.find(r.id) orelse blk: {
        if (self.len == max_records) return false; // table full: drop
        const new = &self.records[self.len];
        self.len += 1;
        new.* = .{};
        @memcpy(new.id_buf[0..r.id.len], r.id);
        new.id_len = @intCast(r.id.len);
        new.since_ns = now;
        break :blk new;
    };

    if (rec.state != state) rec.since_ns = now;
    rec.state = state;
    rec.kind = if (state == .blocked) r.kind else null;
    rec.progress = r.progress;
    rec.app_len = @intCast(copyText(&rec.app_buf, r.app));
    rec.title_len = @intCast(copyText(&rec.title_buf, r.title));
    rec.msg_len = @intCast(copyText(&rec.msg_buf, r.msg));
    return true;
}

/// Remove the record `id` and its descendants; "" removes everything.
pub fn clear(self: *ProgramStatus, id: []const u8) bool {
    if (id.len == 0) {
        const changed = self.len > 0;
        self.len = 0;
        return changed;
    }
    return self.removeWhere(id, matchesSubtree);
}

/// Program exited / shell prompt started: drop working, blocked and idle
/// records; done and error survive.
pub fn dropTransient(self: *ProgramStatus) bool {
    return self.removeWhere({}, isTransient);
}

/// The user has seen the pane: drop done records.
pub fn dropDone(self: *ProgramStatus) bool {
    return self.removeWhere({}, isDone);
}

/// The record that decides the pane's state, or null if the table is empty.
pub fn top(self: *const ProgramStatus) ?*const Record {
    var best: ?*const Record = null;
    for (self.records[0..self.len]) |*rec| {
        const b = best orelse {
            best = rec;
            continue;
        };
        const ru = rec.state.urgency();
        const bu = b.state.urgency();
        if (ru > bu or (ru == bu and rec.since_ns > b.since_ns)) best = rec;
    }
    return best;
}

/// Number of records currently in `state`.
pub fn count(self: *const ProgramStatus, state: State) usize {
    var n: usize = 0;
    for (self.records[0..self.len]) |*rec| {
        if (rec.state == state) n += 1;
    }
    return n;
}

fn find(self: *ProgramStatus, id: []const u8) ?*Record {
    for (self.records[0..self.len]) |*rec| {
        if (std.mem.eql(u8, rec.id(), id)) return rec;
    }
    return null;
}

fn removeWhere(self: *ProgramStatus, ctx: anytype, pred: fn (@TypeOf(ctx), *const Record) bool) bool {
    var w: usize = 0;
    for (self.records[0..self.len]) |rec| {
        if (pred(ctx, &rec)) continue;
        self.records[w] = rec;
        w += 1;
    }
    const changed = w != self.len;
    self.len = w;
    return changed;
}

fn matchesSubtree(prefix: []const u8, rec: *const Record) bool {
    const rid = rec.id();
    if (!std.mem.startsWith(u8, rid, prefix)) return false;
    return rid.len == prefix.len or rid[prefix.len] == '/';
}

fn isTransient(_: void, rec: *const Record) bool {
    return rec.state.transient();
}

fn isDone(_: void, rec: *const Record) bool {
    return rec.state == .done;
}

/// Copy printable text (no control characters), truncated to `dst`.
fn copyText(dst: []u8, src: []const u8) usize {
    var n: usize = 0;
    for (src) |c| {
        if (n == dst.len) break;
        if (c < 0x20 or c == 0x7f) continue;
        dst[n] = c;
        n += 1;
    }
    return n;
}

// ── Tests ────────────────────────────────────────────────

const testing = std.testing;

fn rep(state: StatusReport.State, id: []const u8) StatusReport {
    return .{ .state = state, .id = id };
}

test "root record report and replace" {
    var t: ProgramStatus = .{};
    try testing.expect(t.isEmpty());
    _ = t.apply(.{ .state = .working, .app = "codex" }, 1);
    try testing.expectEqual(State.working, t.top().?.state);
    try testing.expectEqualStrings("codex", t.top().?.app());
    _ = t.apply(.{ .state = .blocked, .kind = .permission, .msg = "Run tests?" }, 2);
    try testing.expectEqual(@as(usize, 1), t.len);
    try testing.expectEqual(State.blocked, t.top().?.state);
    try testing.expectEqual(StatusReport.Kind.permission, t.top().?.kind.?);
    try testing.expectEqualStrings("Run tests?", t.top().?.msg());
}

test "most urgent record wins across sessions" {
    var t: ProgramStatus = .{};
    _ = t.apply(rep(.idle, ""), 1);
    _ = t.apply(rep(.working, "ses_a"), 2);
    _ = t.apply(rep(.done, "ses_b"), 3);
    try testing.expectEqual(State.working, t.top().?.state);
    _ = t.apply(rep(.blocked, "ses_b"), 4);
    try testing.expectEqualStrings("ses_b", t.top().?.id());
    try testing.expectEqual(State.blocked, t.top().?.state);
}

test "clear removes subtree; empty id clears all" {
    var t: ProgramStatus = .{};
    _ = t.apply(rep(.working, "deploy"), 1);
    _ = t.apply(rep(.working, "deploy/us-east"), 1);
    _ = t.apply(rep(.working, "deployment"), 1); // not under "deploy/"
    _ = t.apply(rep(.idle, ""), 1);
    _ = t.apply(rep(.clear, "deploy"), 2);
    try testing.expectEqual(@as(usize, 2), t.len);
    _ = t.apply(rep(.clear, ""), 3);
    try testing.expect(t.isEmpty());
}

test "dropTransient keeps done and error" {
    var t: ProgramStatus = .{};
    _ = t.apply(rep(.working, "a"), 1);
    _ = t.apply(rep(.blocked, "b"), 1);
    _ = t.apply(rep(.idle, "c"), 1);
    _ = t.apply(rep(.done, "d"), 1);
    _ = t.apply(rep(.err, "e"), 1);
    try testing.expect(t.dropTransient());
    try testing.expectEqual(@as(usize, 2), t.len);
    try testing.expectEqual(State.errored, t.top().?.state);
}

test "dropDone removes only done records" {
    var t: ProgramStatus = .{};
    _ = t.apply(rep(.done, "a"), 1);
    _ = t.apply(rep(.err, "b"), 1);
    try testing.expect(t.dropDone());
    try testing.expectEqual(@as(usize, 1), t.len);
    try testing.expect(!t.dropDone());
}

test "since_ns only moves on state change" {
    var t: ProgramStatus = .{};
    _ = t.apply(rep(.working, ""), 10);
    _ = t.apply(.{ .state = .working, .progress = 50 }, 20);
    try testing.expectEqual(@as(i128, 10), t.top().?.since_ns);
    _ = t.apply(rep(.done, ""), 30);
    try testing.expectEqual(@as(i128, 30), t.top().?.since_ns);
}

test "text is sanitized and truncated; table full drops reports" {
    var t: ProgramStatus = .{};
    _ = t.apply(.{ .state = .blocked, .msg = "a\x1b[31mb\x07c" }, 1);
    try testing.expectEqualStrings("a[31mbc", t.top().?.msg());
    var long: [max_text + 40]u8 = undefined;
    @memset(&long, 'x');
    _ = t.apply(.{ .state = .blocked, .msg = &long }, 2);
    try testing.expectEqual(@as(usize, max_text), t.top().?.msg().len);

    var full: ProgramStatus = .{};
    var buf: [8]u8 = undefined;
    for (0..max_records) |i| {
        const id = std.fmt.bufPrint(&buf, "r{d}", .{i}) catch unreachable;
        try testing.expect(full.apply(rep(.working, id), 1));
    }
    try testing.expect(!full.apply(rep(.working, "overflow"), 1));
    try testing.expectEqual(@as(usize, max_records), full.len);
}
