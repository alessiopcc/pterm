/// Notification manager: per-pane cooldown tracking, focus suppression, and dispatch.
///
/// Gates OS desktop notifications by:
///   - Global enabled/disabled toggle (D-19 config)
///   - Window focus suppression (D-05: skip when PTerm is focused)
///   - Per-pane cooldown (D-02: default 30s between notifications per pane)
///
/// Uses AutoHashMapUnmanaged with allocator-per-call pattern (Phase 02 decision).
const std = @import("std");
const notification = @import("notification");

pub const NotificationManager = struct {
    /// Per-pane last notification timestamp (nanoseconds).
    last_notify: std.AutoHashMapUnmanaged(u32, i128),
    /// Cooldown duration in nanoseconds.
    cooldown_ns: i128,
    /// Whether notifications are enabled globally (D-19: agent.notifications).
    enabled: bool,
    /// Whether to suppress notifications when window is focused (D-05).
    suppress_when_focused: bool,
    /// Whether to include sound in notifications (D-19: agent.notification_sound).
    play_sound: bool,

    /// Initialize with config values.
    pub fn init(cooldown_seconds: i64, enabled: bool, suppress_when_focused: bool, play_sound: bool) NotificationManager {
        return .{
            .last_notify = .{},
            .cooldown_ns = @as(i128, cooldown_seconds) * 1_000_000_000,
            .enabled = enabled,
            .suppress_when_focused = suppress_when_focused,
            .play_sound = play_sound,
        };
    }

    /// Check whether a notification should be sent for this pane.
    ///
    /// Returns false if:
    ///   - Notifications are disabled globally
    ///   - Window is focused and suppress_when_focused is true
    ///   - Pane is within cooldown window
    pub fn shouldNotify(self: *const NotificationManager, pane_id: u32, window_focused: bool, now: i128) bool {
        if (!self.enabled) return false;
        if (self.suppress_when_focused and window_focused) return false;

        if (self.last_notify.get(pane_id)) |last_ts| {
            if (now - last_ts < self.cooldown_ns) return false;
        }

        return true;
    }

    /// Record that a notification was sent for a pane.
    pub fn recordNotification(self: *NotificationManager, allocator: std.mem.Allocator, pane_id: u32, now: i128) void {
        self.last_notify.put(allocator, pane_id, now) catch {};
    }

    /// Send a notification if conditions are met, using real wall-clock time.
    pub fn notify(self: *NotificationManager, allocator: std.mem.Allocator, pane_id: u32, pane_identity: []const u8, matched_text: ?[]const u8, window_focused: bool) void {
        const now = std.time.nanoTimestamp();
        self.notifyWithTimestamp(allocator, pane_id, pane_identity, matched_text, window_focused, now);
    }

    /// Testable variant with explicit timestamp.
    pub fn notifyWithTimestamp(self: *NotificationManager, allocator: std.mem.Allocator, pane_id: u32, pane_identity: []const u8, matched_text: ?[]const u8, window_focused: bool, now: i128) void {
        if (!self.shouldNotify(pane_id, window_focused, now)) return;

        const body = notification.formatBody(pane_identity, matched_text);
        notification.sendNotification(notification.TITLE, body.slice(), self.play_sound);
        self.recordNotification(allocator, pane_id, now);
    }

    /// Remove a pane's cooldown entry (pane closed).
    pub fn removePane(self: *NotificationManager, allocator: std.mem.Allocator, pane_id: u32) void {
        _ = allocator;
        _ = self.last_notify.fetchRemove(pane_id);
    }

    /// Update configuration fields (D-20 hot-reload).
    pub fn updateConfig(self: *NotificationManager, cooldown_seconds: i64, enabled: bool, suppress_when_focused: bool, play_sound: bool) void {
        self.cooldown_ns = @as(i128, cooldown_seconds) * 1_000_000_000;
        self.enabled = enabled;
        self.suppress_when_focused = suppress_when_focused;
        self.play_sound = play_sound;
    }

    /// Release hashmap memory.
    pub fn deinit(self: *NotificationManager, allocator: std.mem.Allocator) void {
        self.last_notify.deinit(allocator);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "shouldNotify returns false when enabled=false" {
    const mgr = NotificationManager.init(30, false, true, true);
    try std.testing.expect(!mgr.shouldNotify(1, false, 1_000_000_000));
}

test "shouldNotify returns false when window is focused and suppress_when_focused=true" {
    const mgr = NotificationManager.init(30, true, true, true);
    try std.testing.expect(!mgr.shouldNotify(1, true, 1_000_000_000));
}

test "shouldNotify returns true when window focused but suppress_when_focused=false" {
    const mgr = NotificationManager.init(30, true, false, true);
    try std.testing.expect(mgr.shouldNotify(1, true, 1_000_000_000));
}

test "shouldNotify returns false when within cooldown window" {
    var mgr = NotificationManager.init(30, true, true, true);
    const allocator = std.testing.allocator;
    defer mgr.deinit(allocator);

    const t1: i128 = 1_000_000_000;
    mgr.recordNotification(allocator, 1, t1);

    // 10 seconds later -- still within 30s cooldown
    const t2: i128 = t1 + 10_000_000_000;
    try std.testing.expect(!mgr.shouldNotify(1, false, t2));
}

test "shouldNotify returns true when cooldown has expired" {
    var mgr = NotificationManager.init(30, true, true, true);
    const allocator = std.testing.allocator;
    defer mgr.deinit(allocator);

    const t1: i128 = 1_000_000_000;
    mgr.recordNotification(allocator, 1, t1);

    // 31 seconds later -- cooldown expired
    const t2: i128 = t1 + 31_000_000_000;
    try std.testing.expect(mgr.shouldNotify(1, false, t2));
}

test "recordNotification stores timestamp and subsequent shouldNotify within cooldown returns false" {
    var mgr = NotificationManager.init(30, true, true, true);
    const allocator = std.testing.allocator;
    defer mgr.deinit(allocator);

    const t1: i128 = 5_000_000_000;
    mgr.recordNotification(allocator, 42, t1);

    // Immediately after -- should be in cooldown
    try std.testing.expect(!mgr.shouldNotify(42, false, t1));
    // 1 second later
    try std.testing.expect(!mgr.shouldNotify(42, false, t1 + 1_000_000_000));
}

test "removePane cleans up cooldown entry" {
    var mgr = NotificationManager.init(30, true, true, true);
    const allocator = std.testing.allocator;
    defer mgr.deinit(allocator);

    const t1: i128 = 1_000_000_000;
    mgr.recordNotification(allocator, 1, t1);

    // Within cooldown -- should be false
    try std.testing.expect(!mgr.shouldNotify(1, false, t1 + 1_000_000_000));

    // Remove pane
    mgr.removePane(allocator, 1);

    // After removal -- should be true (no cooldown entry)
    try std.testing.expect(mgr.shouldNotify(1, false, t1 + 1_000_000_000));
}

test "updateConfig changes cooldown" {
    var mgr = NotificationManager.init(30, true, true, true);
    const allocator = std.testing.allocator;
    defer mgr.deinit(allocator);

    const t1: i128 = 1_000_000_000;
    mgr.recordNotification(allocator, 1, t1);

    // Within 30s cooldown
    const t2: i128 = t1 + 15_000_000_000;
    try std.testing.expect(!mgr.shouldNotify(1, false, t2));

    // Change cooldown to 10s
    mgr.updateConfig(10, true, true, true);

    // Now 15s > 10s cooldown -- should be true
    try std.testing.expect(mgr.shouldNotify(1, false, t2));
}

test "updateConfig changes enabled" {
    var mgr = NotificationManager.init(30, true, true, true);

    try std.testing.expect(mgr.shouldNotify(1, false, 1_000_000_000));

    mgr.updateConfig(30, false, true, true);
    try std.testing.expect(!mgr.shouldNotify(1, false, 1_000_000_000));
}

test "init sets cooldown_ns correctly" {
    const mgr = NotificationManager.init(60, true, true, true);
    try std.testing.expectEqual(@as(i128, 60_000_000_000), mgr.cooldown_ns);
}

test "shouldNotify for different panes are independent" {
    var mgr = NotificationManager.init(30, true, true, true);
    const allocator = std.testing.allocator;
    defer mgr.deinit(allocator);

    const t1: i128 = 1_000_000_000;
    mgr.recordNotification(allocator, 1, t1);

    // Pane 1 is in cooldown
    try std.testing.expect(!mgr.shouldNotify(1, false, t1 + 1_000_000_000));
    // Pane 2 has no cooldown entry -- should be allowed
    try std.testing.expect(mgr.shouldNotify(2, false, t1 + 1_000_000_000));
}
