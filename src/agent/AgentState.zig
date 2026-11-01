/// Per-pane agent state machine with atomic cross-thread communication.
///
/// Thread model (mirrors BellState pattern):
///   - Parse thread: applyStatus() / notifyWaiting() / onPromptStart() from
///     escape sequences, onOutput() on raw output
///   - Render thread: inference (onOutput/triggerWaiting/markIdle), markSeen(),
///     agentGone(), consumeFlash(), updateFlash(), reads flash_active, show_badge
///
/// States: idle, working, waiting (needs you), done, errored.
///
/// Two sources of truth, reported beats inferred:
///   - reported: the program's own status records (OSC 7501 / OSC 9;4, see
///     ProgramStatus.zig). While any record exists the pane state is the most
///     urgent record's state, and output does not change it.
///   - inferred: output timing + foreground process (onOutput /
///     triggerWaiting / markIdle). Only used while the table is empty.
///
/// OSC 9 / 777 notifications and agent bells are one-shot: waiting + alert +
/// message, held until output arrives after them (NOTIFY_GRACE_NS later),
/// then inference is back in charge.
///
/// Entering waiting / errored / done raises an alert (pane flash + pending
/// notification), at most once per FLASH_COOLDOWN_NS per state.
/// done becomes idle once the user has seen the pane (markSeen).
const std = @import("std");
const pio = @import("pio");

pub const ProgramStatus = @import("ProgramStatus.zig");
pub const StatusReport = ProgramStatus.StatusReport;

pub const AgentState = struct {
    pub const State = enum(u8) {
        idle,
        working,
        waiting,
        done,
        errored,

        pub fn str(self: State) []const u8 {
            return switch (self) {
                .idle => "idle",
                .working => "working",
                .waiting => "waiting",
                .done => "done",
                .errored => "error",
            };
        }

        /// Whether entering this state should alert the user.
        pub fn alerts(self: State) bool {
            return switch (self) {
                .waiting, .done, .errored => true,
                .idle, .working => false,
            };
        }

        /// Parse a config state name ("waiting", "error", "done", ...).
        /// "needs_you" / "blocked" are accepted for waiting.
        pub fn fromName(name: []const u8) ?State {
            if (std.mem.eql(u8, name, "needs_you") or std.mem.eql(u8, name, "blocked")) return .waiting;
            if (std.mem.eql(u8, name, "error")) return .errored;
            return std.meta.stringToEnum(State, name);
        }

        /// Bit mask (bit = state index) of the named states; unknown names
        /// are ignored.
        pub fn maskFromNames(names: []const []const u8) u32 {
            var mask: u32 = 0;
            for (names) |n| {
                if (fromName(n)) |st| mask |= @as(u32, 1) << @intCast(@backingInt(st));
            }
            return mask;
        }

        fn fromRecord(s: ProgramStatus.State) State {
            return switch (s) {
                .idle => .idle,
                .working => .working,
                .done => .done,
                .blocked => .waiting,
                .errored => .errored,
            };
        }
    };

    pub const Source = enum(u8) { inferred, reported };

    /// State an agent encodes in its window title (status glyph prefix).
    pub const TitleHint = enum(u8) { none, idle, working, waiting };

    /// Classify an agent title by its leading status glyph:
    ///   Claude Code: "✳ " idle; spinner frames (◐◑◒◓, Braille) working
    ///   Gemini CLI:  "◇" idle, "✋" needs you, "✦" / "⏲" working
    ///   Codex:       "[ ! ]" / "[ . ]" Action Required = needs you
    /// Returns the hint and the title text after the glyph.
    pub fn classifyTitle(title: []const u8) struct { hint: TitleHint, text: []const u8 } {
        if (std.mem.startsWith(u8, title, "[ ! ]") or std.mem.startsWith(u8, title, "[ . ]")) {
            return .{ .hint = .waiting, .text = std.mem.trimStart(u8, title[5..], " ") };
        }
        if (title.len == 0) return .{ .hint = .none, .text = "" };
        const len = std.unicode.utf8ByteSequenceLength(title[0]) catch return .{ .hint = .none, .text = title };
        if (len > title.len) return .{ .hint = .none, .text = title };
        const cp = std.unicode.utf8Decode(title[0..len]) catch return .{ .hint = .none, .text = title };
        const hint: TitleHint = switch (cp) {
            0x2733, 0x25C7 => .idle, // ✳ ◇
            0x270B => .waiting, // ✋
            0x2800...0x28FF, 0x25D0...0x25D3, 0x2726, 0x23F2 => .working, // Braille, ◐◑◒◓, ✦, ⏲
            else => .none,
        };
        if (hint == .none) return .{ .hint = .none, .text = title };
        return .{ .hint = hint, .text = std.mem.trimStart(u8, title[len..], " ") };
    }

    /// Flash duration: 150ms UI-SPEC.
    pub const FLASH_DURATION_NS: i128 = 150_000_000;

    /// Flash/notification cooldown per state: 30s. Prevents repeat alerts when
    /// state cycles due to background output while the agent is genuinely
    /// awaiting input.
    pub const FLASH_COOLDOWN_NS: i128 = 30_000_000_000;

    pub const MAX_MESSAGE = ProgramStatus.max_text;

    /// Output this soon after a notification belongs to the same burst (the
    /// redraw that carried the bell) and does not clear it.
    pub const NOTIFY_GRACE_NS: i128 = 500_000_000;

    /// Current state, atomically updated for cross-thread reads.
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.idle),
    /// Whether `state` comes from status records or from inference.
    source: std.atomic.Value(Source) = std.atomic.Value(Source).init(.inferred),
    /// When `state` last changed (elapsed timers).
    since_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    /// Set once an agent process or a status report has been seen in this pane.
    tracked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// A shell prompt started (parse thread); the render thread applies the
    /// lifetime rule once it knows whether an agent is in the foreground.
    prompt_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// When a one-shot notification set waiting (0 = none pending).
    notified_at_ns: i128 = 0,

    /// Status glyph from the agent's window title (parse thread writes).
    title_hint: std.atomic.Value(TitleHint) = std.atomic.Value(TitleHint).init(.none),
    /// Title text after the glyph (session summary). Guarded by `mutex`.
    title_buf: [MAX_MESSAGE]u8 = undefined,
    title_len: usize = 0,

    /// Guards records, message and app.
    mutex: pio.Mutex = .{},
    records: ProgramStatus = .{},
    /// Message for the current state (record msg, else title, else the
    /// notification text).
    message_buf: [MAX_MESSAGE]u8 = undefined,
    message_len: usize = 0,
    /// Reporting app name (e.g. "codex"), from the deciding record.
    app_buf: [ProgramStatus.max_app]u8 = undefined,
    app_len: usize = 0,

    /// Flash overlay active (render thread only after consumeFlash).
    flash_active: bool = false,
    /// Flash start timestamp for duration tracking.
    flash_start_ns: i128 = 0,

    /// Tab badge: set when entering waiting, cleared when leaving it.
    show_badge: bool = false,

    /// Whether this tab is registered as an "agent tab" for enhanced alerts.
    is_agent_tab: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Timestamp when waiting state was entered (for pulse animation elapsed time).
    waiting_start_ns: i128 = 0,

    // ── Pending alert (set by any thread, consumed by render thread) ──
    flash_triggered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Notification pending: set when entering an alerting state, consumed by
    /// the render thread to fire an OS notification for `notify_state`.
    notification_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    notify_state: std.atomic.Value(State) = std.atomic.Value(State).init(.waiting),

    /// Last time an alert fired, per state (cooldown).
    last_alert_ns: [@typeInfo(State).@"enum".field_names.len]i128 = @splat(0),

    // ── Reported state (status records) ──

    /// Apply a program status report (OSC 7501 / OSC 9;4).
    pub fn applyStatus(self: *AgentState, report: StatusReport, now: i128) void {
        self.tracked.store(true, .release);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.records.apply(report, now)) self.syncFromRecords(now);
    }

    /// One-shot "needs you" notification (OSC 9 / 777): waiting + alert +
    /// message, without taking over from inference. Ignored while status
    /// records exist (they are authoritative).
    pub fn notifyWaiting(self: *AgentState, message: []const u8, now: i128) void {
        self.tracked.store(true, .release);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.records.isEmpty()) return;
        self.message_len = copyText(&self.message_buf, message);
        self.setState(.waiting, now);
        self.notified_at_ns = now;
    }

    /// Parse thread: the window title changed.
    pub fn onTitle(self: *AgentState, title: []const u8) void {
        const c = classifyTitle(title);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.title_len = if (c.hint == .none) 0 else copyText(&self.title_buf, c.text);
        self.title_hint.store(c.hint, .release);
    }

    /// Render thread, while an agent runs in the pane: let the title glyph
    /// decide the state (it tracks the agent's own busy flag, e.g. through
    /// quiet subagent runs). Returns false when there is no hint or status
    /// records already decide.
    pub fn applyTitleHint(self: *AgentState, now: i128) bool {
        if (self.hasReports()) return false;
        const new: State = switch (self.title_hint.load(.acquire)) {
            .none => return false,
            .idle => .idle,
            .working => .working,
            .waiting => .waiting,
        };
        // A pending bell / notification stays until the agent works again.
        if (self.notified_at_ns != 0 and new == .idle) return true;
        self.setState(new, now);
        return true;
    }

    /// Copy the title text (status glyph removed) into `buf`.
    pub fn getTitle(self: *AgentState, buf: []u8) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(buf.len, self.title_len);
        @memcpy(buf[0..n], self.title_buf[0..n]);
        return buf[0..n];
    }

    /// Parse thread: a shell prompt started (OSC 133;A).
    pub fn onPromptStart(self: *AgentState) void {
        self.prompt_started.store(true, .release);
    }

    /// Render thread: apply a pending prompt start. Per the status protocol a
    /// new prompt ends in-flight records, but some agents emit prompt marks
    /// around their own messages, so only honour it with no agent running.
    pub fn consumePromptStart(self: *AgentState, agent_in_foreground: bool, now: i128) void {
        if (!self.prompt_started.swap(false, .acq_rel)) return;
        if (agent_in_foreground) return;
        self.dropTransient(now);
    }

    /// The agent process left the foreground: drop in-flight records
    /// (working / blocked / idle); outcomes (done / error) stay until seen.
    pub fn agentGone(self: *AgentState, now: i128) void {
        self.title_hint.store(.none, .release);
        self.dropTransient(now);
    }

    /// Mark that an agent process is (or was) running in this pane.
    pub fn markTracked(self: *AgentState) void {
        self.tracked.store(true, .release);
    }

    /// Whether status records currently drive the state.
    pub fn hasReports(self: *const AgentState) bool {
        return self.source.load(.acquire) == .reported;
    }

    /// The user has looked at this pane: an unread done becomes idle.
    pub fn markSeen(self: *AgentState, now: i128) void {
        if (self.state.load(.acquire) != .done) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.records.dropDone();
        self.syncFromRecords(now);
        if (self.state.load(.acquire) == .done) self.setState(.idle, now);
    }

    /// Copy the current message into `buf`; returns the copied slice.
    pub fn getMessage(self: *AgentState, buf: []u8) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(buf.len, self.message_len);
        @memcpy(buf[0..n], self.message_buf[0..n]);
        return buf[0..n];
    }

    /// Copy the reporting app name into `buf`; returns the copied slice.
    pub fn getApp(self: *AgentState, buf: []u8) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(buf.len, self.app_len);
        @memcpy(buf[0..n], self.app_buf[0..n]);
        return buf[0..n];
    }

    fn dropTransient(self: *AgentState, now: i128) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.records.dropTransient()) self.syncFromRecords(now);
    }

    /// Derive state/message/app from the records (mutex held).
    fn syncFromRecords(self: *AgentState, now: i128) void {
        const rec = self.records.top() orelse {
            // No records left: inference takes over on the next update.
            self.source.store(.inferred, .release);
            return;
        };
        self.source.store(.reported, .release);
        const text = if (rec.msg().len > 0) rec.msg() else rec.title();
        self.message_len = copyText(&self.message_buf, text);
        self.app_len = copyText(&self.app_buf, rec.app());
        self.setState(State.fromRecord(rec.state), now);
    }

    // ── Inferred state (output timing + foreground process) ──

    /// Transition to .waiting (inferred). No-op while status records exist.
    pub fn triggerWaiting(self: *AgentState) void {
        self.triggerWaitingWithTimestamp(pio.nanoTimestamp());
    }

    /// Testable variant with explicit timestamp.
    pub fn triggerWaitingWithTimestamp(self: *AgentState, now: i128) void {
        if (self.hasReports()) return;
        self.setState(.waiting, now);
    }

    /// Terminal output received: inferred .working. No-op while status records
    /// exist, and for output belonging to a pending notification's burst.
    pub fn onOutput(self: *AgentState) void {
        self.onOutputWithTimestamp(pio.nanoTimestamp());
    }

    /// `now` is when the output arrived.
    pub fn onOutputWithTimestamp(self: *AgentState, now: i128) void {
        if (self.hasReports()) return;
        if (self.title_hint.load(.acquire) != .none) return; // title decides
        if (self.notified_at_ns != 0 and now - self.notified_at_ns < NOTIFY_GRACE_NS) return;
        self.setState(.working, now);
    }

    /// Inferred idle (shell in the foreground). No-op while status records
    /// exist; an unseen done also stays.
    pub fn markIdle(self: *AgentState) void {
        self.markIdleWithTimestamp(pio.nanoTimestamp());
    }

    pub fn markIdleWithTimestamp(self: *AgentState, now: i128) void {
        if (self.hasReports()) return;
        if (self.title_hint.load(.acquire) != .none) return; // title decides
        if (self.state.load(.acquire) == .done) return;
        if (self.notified_at_ns != 0) return; // needs you until output follows
        self.setState(.idle, now);
    }

    // ── Transitions ──

    fn setState(self: *AgentState, new: State, now: i128) void {
        const old = self.state.load(.acquire);
        if (old == new) return;
        self.state.store(new, .release);
        self.since_ns.store(@intCast(now), .release);

        if (old == .waiting) {
            self.notified_at_ns = 0;
            self.flash_active = false;
            self.show_badge = false;
            self.flash_triggered.store(false, .release);
            self.notification_pending.store(false, .release);
        }
        if (new == .waiting) {
            self.show_badge = true;
            self.waiting_start_ns = now;
        }
        if (new.alerts()) self.raiseAlert(new, now);
    }

    fn raiseAlert(self: *AgentState, state: State, now: i128) void {
        const idx = @backingInt(state);
        const last = self.last_alert_ns[idx];
        if (last != 0 and now - last < FLASH_COOLDOWN_NS) return;
        self.last_alert_ns[idx] = now;
        self.flash_triggered.store(true, .release);
        self.notify_state.store(state, .release);
        self.notification_pending.store(true, .release);
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

    // ── Render-thread flash handling ──

    /// Consume flash trigger from render thread. Returns true if a flash should start.
    /// Starts the flash timer. Same pattern as BellState.consumeTrigger.
    pub fn consumeFlash(self: *AgentState) bool {
        return self.consumeFlashWithTimestamp(pio.nanoTimestamp());
    }

    /// Testable variant with explicit timestamp.
    pub fn consumeFlashWithTimestamp(self: *AgentState, now: i128) bool {
        if (self.flash_triggered.load(.acquire)) {
            self.flash_triggered.store(false, .release);
            self.flash_active = true;
            self.flash_start_ns = now;
            return true;
        }
        return false;
    }

    /// Update flash state each frame. Clears flash_active after FLASH_DURATION_NS.
    pub fn updateFlash(self: *AgentState) void {
        self.updateFlashWithTimestamp(pio.nanoTimestamp());
    }

    /// Testable variant with explicit timestamp.
    pub fn updateFlashWithTimestamp(self: *AgentState, now: i128) void {
        if (!self.flash_active) return;
        const elapsed = now - self.flash_start_ns;
        if (elapsed >= FLASH_DURATION_NS) {
            self.flash_active = false;
        }
    }

    /// Compute pulse animation alpha for agent tab pulsing border.
    /// Returns f32 in range [0.4, 1.0] using sine wave with ~2s period.
    /// elapsed_ns: time since entering waiting state.
    pub fn computePulseAlpha(elapsed_ns: i128) f32 {
        const t: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 2_000_000_000.0;
        return @floatCast(0.4 + 0.6 * (0.5 + 0.5 * @sin(2.0 * std.math.pi * t)));
    }

    /// Toggle whether this tab is an agent tab.
    pub fn toggleAgentTab(self: *AgentState) void {
        const current = self.is_agent_tab.load(.acquire);
        self.is_agent_tab.store(!current, .release);
    }
};

// ── Tests ────────────────────────────────────────────────

test "init creates idle state" {
    const state = AgentState{};
    try std.testing.expectEqual(AgentState.State.idle, state.state.load(.acquire));
    try std.testing.expect(!state.flash_active);
    try std.testing.expect(!state.show_badge);
    try std.testing.expect(!state.is_agent_tab.load(.acquire));
}

test "triggerWaiting transitions to waiting and sets flash" {
    var state = AgentState{};
    const now: i128 = 1_000_000_000;
    state.triggerWaitingWithTimestamp(now);
    try std.testing.expectEqual(AgentState.State.waiting, state.state.load(.acquire));
    try std.testing.expect(state.show_badge);
    try std.testing.expect(state.flash_triggered.load(.acquire));
    try std.testing.expectEqual(now, state.waiting_start_ns);
}

test "triggerWaiting does not re-flash if already waiting" {
    var state = AgentState{};
    const t1: i128 = 1_000_000_000;
    state.triggerWaitingWithTimestamp(t1);
    // Consume the flash
    _ = state.consumeFlashWithTimestamp(t1);
    try std.testing.expect(!state.flash_triggered.load(.acquire));

    // Trigger again while still waiting -- should be no-op
    const t2: i128 = 2_000_000_000;
    state.triggerWaitingWithTimestamp(t2);
    try std.testing.expect(!state.flash_triggered.load(.acquire));
    // waiting_start_ns should NOT update (still t1)
    try std.testing.expectEqual(t1, state.waiting_start_ns);
}

test "onOutput clears waiting state immediately" {
    var state = AgentState{};
    state.triggerWaitingWithTimestamp(1_000_000_000);
    _ = state.consumeFlashWithTimestamp(1_000_000_000);
    try std.testing.expect(state.flash_active);
    try std.testing.expect(state.show_badge);

    state.onOutput();
    try std.testing.expectEqual(AgentState.State.working, state.state.load(.acquire));
    try std.testing.expect(!state.flash_active);
    try std.testing.expect(!state.show_badge);
}

test "onOutput transitions idle to working" {
    var state = AgentState{};
    try std.testing.expectEqual(AgentState.State.idle, state.state.load(.acquire));
    state.onOutput();
    try std.testing.expectEqual(AgentState.State.working, state.state.load(.acquire));
}

test "markIdle transitions to idle" {
    var state = AgentState{};
    state.onOutput(); // -> working
    state.markIdle();
    try std.testing.expectEqual(AgentState.State.idle, state.state.load(.acquire));
}

test "consumeFlash returns true once after trigger" {
    var state = AgentState{};
    try std.testing.expect(!state.consumeFlashWithTimestamp(0));

    state.triggerWaitingWithTimestamp(1_000_000_000);
    try std.testing.expect(state.consumeFlashWithTimestamp(1_000_000_000));
    // Second consume should return false
    try std.testing.expect(!state.consumeFlashWithTimestamp(1_000_000_000));
}

test "consumeFlash starts flash timer" {
    var state = AgentState{};
    state.triggerWaitingWithTimestamp(1_000_000_000);
    const flash_t: i128 = 1_000_100_000;
    _ = state.consumeFlashWithTimestamp(flash_t);
    try std.testing.expect(state.flash_active);
    try std.testing.expectEqual(flash_t, state.flash_start_ns);
}

test "updateFlash keeps active before 150ms" {
    var state = AgentState{};
    state.triggerWaitingWithTimestamp(1_000_000_000);
    const flash_start: i128 = 1_000_000_000;
    _ = state.consumeFlashWithTimestamp(flash_start);

    // 100ms later -- still active
    state.updateFlashWithTimestamp(flash_start + 100_000_000);
    try std.testing.expect(state.flash_active);
}

test "updateFlash deactivates after 150ms" {
    var state = AgentState{};
    state.triggerWaitingWithTimestamp(1_000_000_000);
    const flash_start: i128 = 1_000_000_000;
    _ = state.consumeFlashWithTimestamp(flash_start);

    // 160ms later -- should deactivate
    state.updateFlashWithTimestamp(flash_start + 160_000_000);
    try std.testing.expect(!state.flash_active);
}

test "computePulseAlpha returns value in range [0.4, 1.0]" {
    // Test at various elapsed times
    const test_times = [_]i128{ 0, 500_000_000, 1_000_000_000, 1_500_000_000, 2_000_000_000 };
    for (test_times) |t| {
        const alpha = AgentState.computePulseAlpha(t);
        try std.testing.expect(alpha >= 0.39); // Allow small floating point tolerance
        try std.testing.expect(alpha <= 1.01);
    }
}

test "computePulseAlpha at t=0 returns 1.0 (peak)" {
    const alpha = AgentState.computePulseAlpha(0);
    // sin(0) = 0, so 0.4 + 0.6 * (0.5 + 0.5 * 0) = 0.4 + 0.3 = 0.7
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), alpha, 0.01);
}

test "is_agent_tab toggle" {
    var state = AgentState{};
    try std.testing.expect(!state.is_agent_tab.load(.acquire));
    state.toggleAgentTab();
    try std.testing.expect(state.is_agent_tab.load(.acquire));
    state.toggleAgentTab();
    try std.testing.expect(!state.is_agent_tab.load(.acquire));
}

test "state transition cycle: idle -> working -> waiting -> working" {
    var state = AgentState{};
    try std.testing.expectEqual(AgentState.State.idle, state.state.load(.acquire));

    state.onOutput(); // idle -> working
    try std.testing.expectEqual(AgentState.State.working, state.state.load(.acquire));

    state.triggerWaitingWithTimestamp(1_000_000_000); // working -> waiting
    try std.testing.expectEqual(AgentState.State.waiting, state.state.load(.acquire));

    state.onOutput(); // waiting -> working
    try std.testing.expectEqual(AgentState.State.working, state.state.load(.acquire));
}

// ── Status records / new states ─────────────────────────

const S = AgentState.State;
const sec: i128 = 1_000_000_000;

test "status report sets state, message, app and source" {
    var st = AgentState{};
    st.applyStatus(.{ .state = .blocked, .kind = .permission, .app = "codex", .msg = "Approve edit?" }, 1 * sec);
    try std.testing.expectEqual(S.waiting, st.state.load(.acquire));
    try std.testing.expect(st.hasReports());
    try std.testing.expect(st.tracked.load(.acquire));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Approve edit?", st.getMessage(&buf));
    try std.testing.expectEqualStrings("codex", st.getApp(&buf));
    try std.testing.expect(st.notification_pending.load(.acquire));
    try std.testing.expectEqual(S.waiting, st.notify_state.load(.acquire));
}

test "output and inference do not override reported state" {
    var st = AgentState{};
    st.applyStatus(.{ .state = .blocked }, 1 * sec);
    st.onOutputWithTimestamp(2 * sec);
    st.markIdleWithTimestamp(3 * sec);
    try std.testing.expectEqual(S.waiting, st.state.load(.acquire));
    st.applyStatus(.{ .state = .idle }, 4 * sec);
    st.triggerWaitingWithTimestamp(5 * sec);
    try std.testing.expectEqual(S.idle, st.state.load(.acquire));
}

test "clear hands control back to inference" {
    var st = AgentState{};
    st.applyStatus(.{ .state = .working }, 1 * sec);
    st.applyStatus(.{ .state = .clear }, 2 * sec);
    try std.testing.expect(!st.hasReports());
    st.triggerWaitingWithTimestamp(3 * sec);
    try std.testing.expectEqual(S.waiting, st.state.load(.acquire));
}

test "most urgent session decides pane state" {
    var st = AgentState{};
    st.applyStatus(.{ .state = .idle, .app = "opencode" }, 1 * sec);
    st.applyStatus(.{ .state = .working, .id = "ses_a" }, 2 * sec);
    try std.testing.expectEqual(S.working, st.state.load(.acquire));
    st.applyStatus(.{ .state = .blocked, .id = "ses_b", .msg = "Input needs response" }, 3 * sec);
    try std.testing.expectEqual(S.waiting, st.state.load(.acquire));
    st.applyStatus(.{ .state = .idle, .id = "ses_b" }, 4 * sec);
    try std.testing.expectEqual(S.working, st.state.load(.acquire));
}

test "done alerts and becomes idle once seen" {
    var st = AgentState{};
    st.applyStatus(.{ .state = .done, .msg = "tests pass" }, 1 * sec);
    try std.testing.expectEqual(S.done, st.state.load(.acquire));
    try std.testing.expectEqual(S.done, st.notify_state.load(.acquire));
    st.markSeen(2 * sec);
    try std.testing.expectEqual(S.idle, st.state.load(.acquire));
    try std.testing.expect(!st.hasReports());
}

test "agent exit drops in-flight records, keeps error" {
    var st = AgentState{};
    st.applyStatus(.{ .state = .working }, 1 * sec);
    st.agentGone(2 * sec);
    try std.testing.expect(!st.hasReports());

    var st2 = AgentState{};
    st2.applyStatus(.{ .state = .err, .msg = "build failed" }, 1 * sec);
    st2.agentGone(2 * sec);
    try std.testing.expect(st2.hasReports());
    try std.testing.expectEqual(S.errored, st2.state.load(.acquire));
}

test "prompt start ends in-flight records only without a running agent" {
    var st = AgentState{};
    st.applyStatus(.{ .state = .working }, 1 * sec);
    st.onPromptStart();
    st.consumePromptStart(true, 2 * sec); // agent emits prompt marks itself
    try std.testing.expect(st.hasReports());
    st.onPromptStart();
    st.consumePromptStart(false, 3 * sec); // back at the shell
    try std.testing.expect(!st.hasReports());
}

test "alert cooldown is per state" {
    var st = AgentState{};
    st.applyStatus(.{ .state = .blocked }, 1 * sec);
    st.notification_pending.store(false, .release);
    st.applyStatus(.{ .state = .done }, 2 * sec); // different state: alerts
    try std.testing.expect(st.notification_pending.load(.acquire));
    try std.testing.expectEqual(S.done, st.notify_state.load(.acquire));

    st.notification_pending.store(false, .release);
    st.applyStatus(.{ .state = .blocked }, 3 * sec); // waiting again within 30s
    try std.testing.expect(!st.notification_pending.load(.acquire));
}

test "notification sets waiting but output resumes working" {
    var st = AgentState{};
    st.notifyWaiting("Claude needs your permission", 1 * sec);
    try std.testing.expectEqual(S.waiting, st.state.load(.acquire));
    try std.testing.expect(!st.hasReports());
    try std.testing.expect(st.notification_pending.load(.acquire));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Claude needs your permission", st.getMessage(&buf));
    st.onOutputWithTimestamp(2 * sec);
    try std.testing.expectEqual(S.working, st.state.load(.acquire));
}

test "notification holds through quiet and its own output burst" {
    var st = AgentState{};
    st.notifyWaiting("", 10 * sec);
    st.markIdleWithTimestamp(11 * sec); // quiet agent: still needs you
    try std.testing.expectEqual(S.waiting, st.state.load(.acquire));
    st.onOutputWithTimestamp(10 * sec + 200_000_000); // same redraw burst
    try std.testing.expectEqual(S.waiting, st.state.load(.acquire));
    st.onOutputWithTimestamp(9 * sec); // output from before the bell
    try std.testing.expectEqual(S.waiting, st.state.load(.acquire));
    st.onOutputWithTimestamp(12 * sec); // user typed / agent resumed
    try std.testing.expectEqual(S.working, st.state.load(.acquire));
    st.markIdleWithTimestamp(13 * sec); // notification consumed
    try std.testing.expectEqual(S.idle, st.state.load(.acquire));
}

test "classifyTitle reads agent status glyphs" {
    const C = AgentState;
    try std.testing.expectEqual(C.TitleHint.idle, C.classifyTitle("✳ Write two notes").hint);
    try std.testing.expectEqualStrings("Write two notes", C.classifyTitle("✳ Write two notes").text);
    try std.testing.expectEqual(C.TitleHint.working, C.classifyTitle("◑ Second branch").hint);
    try std.testing.expectEqual(C.TitleHint.working, C.classifyTitle("⠋ Refactor").hint);
    try std.testing.expectEqual(C.TitleHint.waiting, C.classifyTitle("✋  Action Required (repo)").hint);
    try std.testing.expectEqual(C.TitleHint.waiting, C.classifyTitle("[ ! ] Action Required").hint);
    try std.testing.expectEqual(C.TitleHint.idle, C.classifyTitle("◇  Ready (repo)").hint);
    try std.testing.expectEqual(C.TitleHint.none, C.classifyTitle("nu - ~/project").hint);
    try std.testing.expectEqual(C.TitleHint.none, C.classifyTitle("").hint);
}

test "title hint drives state through quiet periods and ignores output" {
    var st = AgentState{};
    st.onTitle("◐ Running subagents");
    try std.testing.expect(st.applyTitleHint(1 * sec));
    try std.testing.expectEqual(S.working, st.state.load(.acquire));
    st.markIdleWithTimestamp(5 * sec); // quiet, but the title says working
    try std.testing.expectEqual(S.working, st.state.load(.acquire));
    st.onTitle("✳ Running subagents");
    _ = st.applyTitleHint(6 * sec);
    try std.testing.expectEqual(S.idle, st.state.load(.acquire));
    st.onOutputWithTimestamp(7 * sec); // typing echo does not flip to working
    try std.testing.expectEqual(S.idle, st.state.load(.acquire));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Running subagents", st.getTitle(&buf));
    st.agentGone(8 * sec);
    try std.testing.expect(!st.applyTitleHint(9 * sec));
}

test "status records beat title hints" {
    var st = AgentState{};
    st.applyStatus(.{ .state = .blocked }, 1 * sec);
    st.onTitle("◐ busy");
    try std.testing.expect(!st.applyTitleHint(2 * sec));
    try std.testing.expectEqual(S.waiting, st.state.load(.acquire));
}

test "notification is ignored while status records exist" {
    var st = AgentState{};
    st.applyStatus(.{ .state = .working }, 1 * sec);
    st.notifyWaiting("ping", 2 * sec);
    try std.testing.expectEqual(S.working, st.state.load(.acquire));
}

test "inferred idle keeps an unseen done" {
    var st = AgentState{};
    st.applyStatus(.{ .state = .done }, 1 * sec);
    st.applyStatus(.{ .state = .clear }, 2 * sec);
    st.markIdleWithTimestamp(3 * sec);
    try std.testing.expectEqual(S.done, st.state.load(.acquire));
}

test "state names and notify mask" {
    try std.testing.expectEqual(S.waiting, S.fromName("waiting").?);
    try std.testing.expectEqual(S.waiting, S.fromName("needs_you").?);
    try std.testing.expectEqual(S.errored, S.fromName("error").?);
    try std.testing.expectEqual(S.done, S.fromName("done").?);
    try std.testing.expect(S.fromName("bogus") == null);
    const names = [_][]const u8{ "waiting", "done", "bogus" };
    const mask = S.maskFromNames(&names);
    try std.testing.expect(mask & (1 << @backingInt(S.waiting)) != 0);
    try std.testing.expect(mask & (1 << @backingInt(S.done)) != 0);
    try std.testing.expect(mask & (1 << @backingInt(S.errored)) == 0);
}

test {
    _ = ProgramStatus;
}
