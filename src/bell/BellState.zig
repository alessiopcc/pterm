/// Per-pane bell state with atomic trigger, flash timer, rate limiter, and badge flag.
///
/// Thread model:
///   - Read thread: calls `trigger()` or `triggerWithTimestamp()` when BEL byte (0x07) detected.
///   - Render thread: calls `consumeTrigger()`, `updateFlash()`, reads `flash_active`, `show_badge`.
///
/// Timing constants from UI-SPEC / CONTEXT decisions:
///   - flash duration 120ms
///   - rate limit 500ms
const std = @import("std");

pub const BellState = struct {
    /// Set by read thread (Observer.onBell), read by render thread.
    triggered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Flash overlay timing (render thread only -- no atomics needed).
    flash_active: bool = false,
    flash_start_ns: i128 = 0,

    /// Rate limiter: timestamp of last accepted bell trigger (read thread).
    last_bell_ns: i128 = 0,

    /// Tab badge (set on bell, cleared on tab focus).
    show_badge: bool = false,

    pub const FLASH_DURATION_NS: i128 = 120_000_000; // 120ms
    pub const RATE_LIMIT_NS: i128 = 500_000_000; // 500ms

    /// Called from read thread when BEL detected. Thread-safe via atomic.
    /// Returns true if bell was accepted (not rate-limited).
    pub fn trigger(self: *BellState) bool {
        return self.triggerWithTimestamp(std.time.nanoTimestamp());
    }

    /// Testable variant that accepts explicit timestamp.
    pub fn triggerWithTimestamp(self: *BellState, now: i128) bool {
        if (now - self.last_bell_ns < RATE_LIMIT_NS) return false;
        self.last_bell_ns = now;
        self.triggered.store(true, .release);
        self.show_badge = true;
        return true;
    }

    /// Called from render thread to start flash if triggered.
    /// Returns true if a new flash started.
    pub fn consumeTrigger(self: *BellState) bool {
        if (self.triggered.load(.acquire)) {
            self.triggered.store(false, .release);
            self.flash_active = true;
            self.flash_start_ns = std.time.nanoTimestamp();
            return true;
        }
        return false;
    }

    /// Testable variant that accepts explicit timestamp for flash start.
    pub fn consumeTriggerWithTimestamp(self: *BellState, now: i128) bool {
        if (self.triggered.load(.acquire)) {
            self.triggered.store(false, .release);
            self.flash_active = true;
            self.flash_start_ns = now;
            return true;
        }
        return false;
    }

    /// Called from render thread each frame to update flash state.
    pub fn updateFlash(self: *BellState) void {
        if (!self.flash_active) return;
        const elapsed = std.time.nanoTimestamp() - self.flash_start_ns;
        if (elapsed >= FLASH_DURATION_NS) {
            self.flash_active = false;
        }
    }

    /// Testable variant that accepts explicit timestamp.
    pub fn updateFlashWithTimestamp(self: *BellState, now: i128) void {
        if (!self.flash_active) return;
        const elapsed = now - self.flash_start_ns;
        if (elapsed >= FLASH_DURATION_NS) {
            self.flash_active = false;
        }
    }

    pub fn clearBadge(self: *BellState) void {
        self.show_badge = false;
    }
};

// ── Tests ────────────────────────────────────────────────

test "trigger sets triggered and updates last_bell_ns" {
    var state = BellState{};
    const now: i128 = 1_000_000_000; // 1 second
    const accepted = state.triggerWithTimestamp(now);
    try std.testing.expect(accepted);
    try std.testing.expect(state.triggered.load(.acquire));
    try std.testing.expectEqual(now, state.last_bell_ns);
}

test "trigger within 500ms is rate limited" {
    var state = BellState{};
    const t1: i128 = 1_000_000_000;
    _ = state.triggerWithTimestamp(t1);
    // Consume so triggered resets
    _ = state.consumeTriggerWithTimestamp(t1);

    // 200ms later -- should be rate limited
    const t2: i128 = t1 + 200_000_000;
    const accepted = state.triggerWithTimestamp(t2);
    try std.testing.expect(!accepted);
}

test "trigger after 500ms is accepted" {
    var state = BellState{};
    const t1: i128 = 1_000_000_000;
    _ = state.triggerWithTimestamp(t1);
    _ = state.consumeTriggerWithTimestamp(t1);

    // 600ms later -- should be accepted
    const t2: i128 = t1 + 600_000_000;
    const accepted = state.triggerWithTimestamp(t2);
    try std.testing.expect(accepted);
}

test "trigger sets show_badge" {
    var state = BellState{};
    _ = state.triggerWithTimestamp(1_000_000_000);
    try std.testing.expect(state.show_badge);
}

test "consumeTrigger returns true when triggered, false otherwise" {
    var state = BellState{};
    try std.testing.expect(!state.consumeTriggerWithTimestamp(0));

    _ = state.triggerWithTimestamp(1_000_000_000);
    try std.testing.expect(state.consumeTriggerWithTimestamp(1_000_000_000));
    // Second consume should be false
    try std.testing.expect(!state.consumeTriggerWithTimestamp(1_000_000_000));
}

test "consumeTrigger starts flash" {
    var state = BellState{};
    _ = state.triggerWithTimestamp(1_000_000_000);
    const t: i128 = 1_000_100_000;
    _ = state.consumeTriggerWithTimestamp(t);
    try std.testing.expect(state.flash_active);
    try std.testing.expectEqual(t, state.flash_start_ns);
}

test "updateFlash keeps active before 120ms" {
    var state = BellState{};
    _ = state.triggerWithTimestamp(1_000_000_000);
    const flash_start: i128 = 1_000_000_000;
    _ = state.consumeTriggerWithTimestamp(flash_start);

    // 50ms later -- still active
    state.updateFlashWithTimestamp(flash_start + 50_000_000);
    try std.testing.expect(state.flash_active);
}

test "updateFlash deactivates after 120ms" {
    var state = BellState{};
    _ = state.triggerWithTimestamp(1_000_000_000);
    const flash_start: i128 = 1_000_000_000;
    _ = state.consumeTriggerWithTimestamp(flash_start);

    // 130ms later -- should deactivate
    state.updateFlashWithTimestamp(flash_start + 130_000_000);
    try std.testing.expect(!state.flash_active);
}

test "clearBadge resets show_badge" {
    var state = BellState{};
    _ = state.triggerWithTimestamp(1_000_000_000);
    try std.testing.expect(state.show_badge);
    state.clearBadge();
    try std.testing.expect(!state.show_badge);
}
