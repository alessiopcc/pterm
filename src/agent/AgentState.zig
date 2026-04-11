/// Per-pane agent state machine with atomic cross-thread communication.
///
/// Thread model (mirrors BellState pattern):
///   - Parser/reader thread: calls triggerWaiting(), onOutput(), markIdle()
///   - Render thread: calls consumeFlash(), updateFlash(), reads flash_active, show_badge
///
/// State transitions:
///   idle -> working  (on any terminal output via onOutput)
///   working -> waiting  (on pattern match or idle timeout via triggerWaiting)
///   waiting -> working  (on terminal output via onOutput -- instant clear per D-04)
///   working -> idle  (via markIdle)
///
/// Flash fires once on first entry to .waiting state (D-16).
/// Pulse animation runs continuously while in .waiting state.
const std = @import("std");

pub const AgentState = struct {
    /// Three-state machine: idle, working, waiting.
    pub const State = enum(u8) { idle, working, waiting };

    /// Flash duration: 150ms per D-16 UI-SPEC.
    pub const FLASH_DURATION_NS: i128 = 150_000_000;

    /// Current state, atomically updated for cross-thread reads.
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.idle),

    /// Flash overlay active (render thread only after consumeFlash).
    flash_active: bool = false,
    /// Flash start timestamp for duration tracking.
    flash_start_ns: i128 = 0,

    /// Tab badge: set when entering waiting, cleared on output.
    show_badge: bool = false,

    /// Whether this tab is registered as an "agent tab" for enhanced alerts (D-10).
    is_agent_tab: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Timestamp when waiting state was entered (for pulse animation elapsed time).
    waiting_start_ns: i128 = 0,

    // ── Internal: pending flash trigger (set by parser thread, consumed by render thread) ──
    flash_triggered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Notification pending: set when entering .waiting, consumed by render thread to fire OS notification.
    notification_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Transition to .waiting state. Called when pattern match or idle timeout detected.
    /// Flash fires only on first entry (not re-entry while already waiting).
    pub fn triggerWaiting(self: *AgentState) void {
        self.triggerWaitingWithTimestamp(std.time.nanoTimestamp());
    }

    /// Testable variant with explicit timestamp.
    pub fn triggerWaitingWithTimestamp(self: *AgentState, now: i128) void {
        // Only trigger flash on first entry to waiting (not if already waiting)
        if (self.state.load(.acquire) == .waiting) return;
        self.state.store(.waiting, .release);
        self.flash_triggered.store(true, .release);
        self.notification_pending.store(true, .release);
        self.show_badge = true;
        self.waiting_start_ns = now;
    }

    /// Called when terminal output received. Instantly clears waiting state (D-04).
    /// Transitions to .working regardless of previous state.
    pub fn onOutput(self: *AgentState) void {
        const current = self.state.load(.acquire);
        if (current == .waiting) {
            self.flash_active = false;
            self.show_badge = false;
            self.flash_triggered.store(false, .release);
            self.notification_pending.store(false, .release);
        }
        self.state.store(.working, .release);
    }

    /// Transition to idle state.
    pub fn markIdle(self: *AgentState) void {
        self.state.store(.idle, .release);
    }

    /// Consume flash trigger from render thread. Returns true if a flash should start.
    /// Starts the flash timer. Same pattern as BellState.consumeTrigger.
    pub fn consumeFlash(self: *AgentState) bool {
        return self.consumeFlashWithTimestamp(std.time.nanoTimestamp());
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
        self.updateFlashWithTimestamp(std.time.nanoTimestamp());
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

    /// Toggle whether this tab is an agent tab (D-10).
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

test "onOutput clears waiting state immediately (D-04)" {
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

    state.onOutput(); // waiting -> working (D-04 instant clear)
    try std.testing.expectEqual(AgentState.State.working, state.state.load(.acquire));
}
