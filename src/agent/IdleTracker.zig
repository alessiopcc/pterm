/// Timer-based idle detection for agent monitoring.
///
/// Tracks the last time terminal output was received in a pane.
/// Reports idle when no output has been received for the configured timeout.
///
/// Thread model: Called from the parser/reader thread (recordOutput) and
/// queried from the render thread (isIdle). Fields are not atomic because
/// one stale frame (16ms) is acceptable for idle detection.
///
/// Per idle detection is optional, off by default, with 5-second default timeout.
const std = @import("std");

pub const IdleTracker = struct {
    /// Timeout in nanoseconds before declaring idle.
    timeout_ns: i128,
    /// Timestamp of last output event (nanoseconds).
    last_output_ns: i128,
    /// Whether idle detection is enabled.
    enabled: bool,

    /// Create a new IdleTracker.
    /// timeout_seconds: idle threshold in seconds (converted to nanoseconds internally).
    /// enabled: if false, isIdle() always returns false.
    pub fn init(timeout_seconds: u32, enabled: bool) IdleTracker {
        return .{
            .timeout_ns = @as(i128, timeout_seconds) * 1_000_000_000,
            .last_output_ns = 0,
            .enabled = enabled,
        };
    }

    /// Record that output was received at the given timestamp.
    pub fn recordOutput(self: *IdleTracker, now: i128) void {
        self.last_output_ns = now;
    }

    /// Record output at the current wall-clock time.
    pub fn recordOutputNow(self: *IdleTracker) void {
        self.recordOutput(std.time.nanoTimestamp());
    }

    /// Check if the pane is idle (no output for timeout_ns).
    /// Returns false if:
    ///   - idle detection is disabled
    ///   - no output has ever been recorded (last_output_ns == 0)
    ///   - timeout has not elapsed
    pub fn isIdle(self: *const IdleTracker, now: i128) bool {
        if (!self.enabled) return false;
        if (self.last_output_ns == 0) return false;
        return (now - self.last_output_ns) >= self.timeout_ns;
    }
};

// ── Tests ────────────────────────────────────────────────

test "init sets timeout correctly" {
    const tracker = IdleTracker.init(5, true);
    try std.testing.expectEqual(@as(i128, 5_000_000_000), tracker.timeout_ns);
    try std.testing.expectEqual(@as(i128, 0), tracker.last_output_ns);
    try std.testing.expect(tracker.enabled);
}

test "isIdle returns false when disabled" {
    const tracker = IdleTracker.init(5, false);
    try std.testing.expect(!tracker.isIdle(10_000_000_000));
}

test "isIdle returns false when no output recorded" {
    const tracker = IdleTracker.init(5, true);
    try std.testing.expect(!tracker.isIdle(10_000_000_000));
}

test "isIdle returns false immediately after recordOutput" {
    var tracker = IdleTracker.init(5, true);
    const now: i128 = 10_000_000_000;
    tracker.recordOutput(now);
    try std.testing.expect(!tracker.isIdle(now));
    // 1 second later -- not yet idle
    try std.testing.expect(!tracker.isIdle(now + 1_000_000_000));
}

test "isIdle returns true after timeout elapsed" {
    var tracker = IdleTracker.init(5, true);
    const t1: i128 = 10_000_000_000;
    tracker.recordOutput(t1);
    // 5 seconds later -- exactly at threshold
    try std.testing.expect(tracker.isIdle(t1 + 5_000_000_000));
    // 6 seconds later -- past threshold
    try std.testing.expect(tracker.isIdle(t1 + 6_000_000_000));
}

test "recordOutput resets idle timer" {
    var tracker = IdleTracker.init(5, true);
    const t1: i128 = 10_000_000_000;
    tracker.recordOutput(t1);
    // 4 seconds later, not idle
    try std.testing.expect(!tracker.isIdle(t1 + 4_000_000_000));
    // New output at t1 + 4s
    tracker.recordOutput(t1 + 4_000_000_000);
    // 4 more seconds (t1 + 8s) -- not idle yet (only 4s since last output)
    try std.testing.expect(!tracker.isIdle(t1 + 8_000_000_000));
    // 5 more seconds (t1 + 9s) -- idle (5s since last output at t1+4)
    try std.testing.expect(tracker.isIdle(t1 + 9_000_000_000));
}
