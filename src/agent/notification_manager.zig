/// Notification manager: per-pane, per-kind cooldown tracking, focus
/// suppression, and dispatch.
///
/// Gates OS desktop notifications by:
///   - Global enabled/disabled toggle
///   - Kind filter (`kind_mask`; a kind is e.g. an agent state index)
///   - Window focus suppression
///   - Per-pane, per-kind cooldown (a "done" never suppresses a later
///     "needs you" for the same pane)
///
/// Uses AutoHashMapUnmanaged with allocator-per-call pattern.
const std = @import("std");
const pio = @import("pio");
const notification = @import("notification");

pub const NotificationManager = struct {
    pub const Key = struct { pane_id: u32, kind: u8 };

    /// Last notification timestamp (nanoseconds) per pane and kind.
    last_notify: std.AutoHashMapUnmanaged(Key, i128),
    /// Bit `k` set = kind `k` may notify. All kinds by default.
    kind_mask: u32 = std.math.maxInt(u32),
    /// Cooldown duration in nanoseconds.
    cooldown_ns: i128,
    /// Whether notifications are enabled globally.
    enabled: bool,
    /// Whether to suppress notifications when window is focused.
    suppress_when_focused: bool,
    /// Whether to include sound in notifications.
    play_sound: bool,

    /// Initialize with config values.
    pub fn init(cooldown_seconds: i64, enabled: bool, suppress_when_focused: bool, play_sound: bool) NotificationManager {
        return .{
            .last_notify = .empty,
            .cooldown_ns = @as(i128, cooldown_seconds) * 1_000_000_000,
            .enabled = enabled,
            .suppress_when_focused = suppress_when_focused,
            .play_sound = play_sound,
        };
    }

    /// Check whether a notification of `kind` should be sent for this pane.
    ///
    /// Returns false if:
    ///   - Notifications are disabled globally
    ///   - `kind` is filtered out by `kind_mask`
    ///   - Window is focused and suppress_when_focused is true
    ///   - Pane is within the cooldown window for this kind
    pub fn shouldNotify(self: *const NotificationManager, pane_id: u32, kind: u8, window_focused: bool, now: i128) bool {
        if (!self.enabled) return false;
        if (kind >= 32 or self.kind_mask & (@as(u32, 1) << @intCast(kind)) == 0) return false;
        if (self.suppress_when_focused and window_focused) return false;

        if (self.last_notify.get(.{ .pane_id = pane_id, .kind = kind })) |last_ts| {
            if (now - last_ts < self.cooldown_ns) return false;
        }

        return true;
    }

    /// Record that a notification of `kind` was sent for a pane.
    pub fn recordNotification(self: *NotificationManager, allocator: std.mem.Allocator, pane_id: u32, kind: u8, now: i128) void {
        self.last_notify.put(allocator, .{ .pane_id = pane_id, .kind = kind }, now) catch {};
    }

    /// Send a notification if conditions are met, using real wall-clock time.
    pub fn notify(self: *NotificationManager, allocator: std.mem.Allocator, pane_id: u32, kind: u8, pane_identity: []const u8, matched_text: ?[]const u8, window_focused: bool) void {
        const now = pio.nanoTimestamp();
        self.notifyWithTimestamp(allocator, pane_id, kind, pane_identity, matched_text, window_focused, now);
    }

    /// Testable variant with explicit timestamp.
    pub fn notifyWithTimestamp(self: *NotificationManager, allocator: std.mem.Allocator, pane_id: u32, kind: u8, pane_identity: []const u8, matched_text: ?[]const u8, window_focused: bool, now: i128) void {
        if (!self.shouldNotify(pane_id, kind, window_focused, now)) return;

        const body = notification.formatBody(pane_identity, matched_text);
        notification.sendNotification(notification.TITLE, body.slice(), self.play_sound);
        self.recordNotification(allocator, pane_id, kind, now);
    }

    /// Remove a pane's cooldown entries (pane closed).
    pub fn removePane(self: *NotificationManager, pane_id: u32) void {
        var it = self.last_notify.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.pane_id == pane_id) {
                self.last_notify.removeByPtr(entry.key_ptr);
                it = self.last_notify.iterator(); // restart: removal invalidates
            }
        }
    }

    /// Restrict notifications to the kinds whose bit is set.
    pub fn setKindMask(self: *NotificationManager, mask: u32) void {
        self.kind_mask = mask;
    }

    /// Update configuration fields.
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
    try std.testing.expect(!mgr.shouldNotify(1, 0, false, 1_000_000_000));
}

test "shouldNotify returns false when window is focused and suppress_when_focused=true" {
    const mgr = NotificationManager.init(30, true, true, true);
    try std.testing.expect(!mgr.shouldNotify(1, 0, true, 1_000_000_000));
}

test "shouldNotify returns true when window focused but suppress_when_focused=false" {
    const mgr = NotificationManager.init(30, true, false, true);
    try std.testing.expect(mgr.shouldNotify(1, 0, true, 1_000_000_000));
}

test "shouldNotify returns false when within cooldown window" {
    var mgr = NotificationManager.init(30, true, true, true);
    const allocator = std.testing.allocator;
    defer mgr.deinit(allocator);

    const t1: i128 = 1_000_000_000;
    mgr.recordNotification(allocator, 1, 0, t1);

    // 10 seconds later -- still within 30s cooldown
    const t2: i128 = t1 + 10_000_000_000;
    try std.testing.expect(!mgr.shouldNotify(1, 0, false, t2));
}

test "shouldNotify returns true when cooldown has expired" {
    var mgr = NotificationManager.init(30, true, true, true);
    const allocator = std.testing.allocator;
    defer mgr.deinit(allocator);

    const t1: i128 = 1_000_000_000;
    mgr.recordNotification(allocator, 1, 0, t1);

    // 31 seconds later -- cooldown expired
    const t2: i128 = t1 + 31_000_000_000;
    try std.testing.expect(mgr.shouldNotify(1, 0, false, t2));
}

test "recordNotification stores timestamp and subsequent shouldNotify within cooldown returns false" {
    var mgr = NotificationManager.init(30, true, true, true);
    const allocator = std.testing.allocator;
    defer mgr.deinit(allocator);

    const t1: i128 = 5_000_000_000;
    mgr.recordNotification(allocator, 42, 0, t1);

    // Immediately after -- should be in cooldown
    try std.testing.expect(!mgr.shouldNotify(42, 0, false, t1));
    // 1 second later
    try std.testing.expect(!mgr.shouldNotify(42, 0, false, t1 + 1_000_000_000));
}

test "removePane cleans up cooldown entry" {
    var mgr = NotificationManager.init(30, true, true, true);
    const allocator = std.testing.allocator;
    defer mgr.deinit(allocator);

    const t1: i128 = 1_000_000_000;
    mgr.recordNotification(allocator, 1, 0, t1);

    // Within cooldown -- should be false
    try std.testing.expect(!mgr.shouldNotify(1, 0, false, t1 + 1_000_000_000));

    // Remove pane
    mgr.removePane(1);

    // After removal -- should be true (no cooldown entry)
    try std.testing.expect(mgr.shouldNotify(1, 0, false, t1 + 1_000_000_000));
}

test "updateConfig changes cooldown" {
    var mgr = NotificationManager.init(30, true, true, true);
    const allocator = std.testing.allocator;
    defer mgr.deinit(allocator);

    const t1: i128 = 1_000_000_000;
    mgr.recordNotification(allocator, 1, 0, t1);

    // Within 30s cooldown
    const t2: i128 = t1 + 15_000_000_000;
    try std.testing.expect(!mgr.shouldNotify(1, 0, false, t2));

    // Change cooldown to 10s
    mgr.updateConfig(10, true, true, true);

    // Now 15s > 10s cooldown -- should be true
    try std.testing.expect(mgr.shouldNotify(1, 0, false, t2));
}

test "updateConfig changes enabled" {
    var mgr = NotificationManager.init(30, true, true, true);

    try std.testing.expect(mgr.shouldNotify(1, 0, false, 1_000_000_000));

    mgr.updateConfig(30, false, true, true);
    try std.testing.expect(!mgr.shouldNotify(1, 0, false, 1_000_000_000));
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
    mgr.recordNotification(allocator, 1, 0, t1);

    // Pane 1 is in cooldown
    try std.testing.expect(!mgr.shouldNotify(1, 0, false, t1 + 1_000_000_000));
    // Pane 2 has no cooldown entry -- should be allowed
    try std.testing.expect(mgr.shouldNotify(2, 0, false, t1 + 1_000_000_000));
}

test "cooldown is per kind for the same pane" {
    var mgr = NotificationManager.init(30, true, true, true);
    const allocator = std.testing.allocator;
    defer mgr.deinit(allocator);

    mgr.recordNotification(allocator, 1, 3, 1_000_000_000); // e.g. done
    try std.testing.expect(!mgr.shouldNotify(1, 3, false, 2_000_000_000));
    try std.testing.expect(mgr.shouldNotify(1, 2, false, 2_000_000_000)); // e.g. waiting
}

test "kind mask filters kinds" {
    var mgr = NotificationManager.init(30, true, true, true);
    mgr.setKindMask(1 << 2);
    try std.testing.expect(mgr.shouldNotify(1, 2, false, 1_000_000_000));
    try std.testing.expect(!mgr.shouldNotify(1, 3, false, 1_000_000_000));
}

test "removePane clears every kind for that pane only" {
    var mgr = NotificationManager.init(30, true, true, true);
    const allocator = std.testing.allocator;
    defer mgr.deinit(allocator);

    mgr.recordNotification(allocator, 1, 2, 1_000_000_000);
    mgr.recordNotification(allocator, 1, 3, 1_000_000_000);
    mgr.recordNotification(allocator, 2, 2, 1_000_000_000);
    mgr.removePane(1);
    try std.testing.expect(mgr.shouldNotify(1, 2, false, 2_000_000_000));
    try std.testing.expect(mgr.shouldNotify(1, 3, false, 2_000_000_000));
    try std.testing.expect(!mgr.shouldNotify(2, 2, false, 2_000_000_000));
}
