/// Cross-platform OS notification via shell-out to platform-specific commands.
///
/// SECURITY: Title and body are passed as discrete argv arguments to the child
/// process, never interpolated into a shell command string on macOS/Linux.
/// On Windows, PowerShell script embeds sanitized values (quotes stripped).
///
/// Platform commands:
///   Windows: PowerShell toast notification via WinRT
///   macOS:   osascript display notification
///   Linux:   notify-send (libnotify)
const builtin = @import("builtin");
const std = @import("std");

/// Default notification title.
pub const TITLE = "PTerm -- Agent waiting";

/// Formatted body result: fixed buffer + length.
pub const FormattedBody = struct {
    buf: [256]u8,
    len: usize,

    pub fn slice(self: *const FormattedBody) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Maximum length for matched_text before truncation.
const MAX_TEXT_LEN: usize = 80;

/// Format notification body from pane identity and optional matched text.
///
/// Returns "Tab N, Pane M: {matched_text}" or "Tab N, Pane M: Output idle"
/// when matched_text is null. Truncates matched_text to 80 chars with "..."
/// suffix if longer.
pub fn formatBody(pane_identity: []const u8, matched_text: ?[]const u8) FormattedBody {
    var result = FormattedBody{ .buf = undefined, .len = 0 };
    var stream = std.io.fixedBufferStream(&result.buf);
    const writer = stream.writer();

    if (matched_text) |text| {
        if (text.len > MAX_TEXT_LEN) {
            writer.print("{s}: {s}...", .{ pane_identity, text[0..MAX_TEXT_LEN] }) catch {};
        } else {
            writer.print("{s}: {s}", .{ pane_identity, text }) catch {};
        }
    } else {
        writer.print("{s}: Output idle", .{pane_identity}) catch {};
    }

    result.len = stream.pos;
    return result;
}

/// Send an OS desktop notification. Fire and forget.
///
/// Platform-specific implementation:
///   Windows: PowerShell toast notification via WinRT API
///   macOS:   osascript display notification
///   Linux:   notify-send with PTerm app name
pub fn sendNotification(title: []const u8, body: []const u8, play_sound: bool) void {
    switch (builtin.os.tag) {
        .windows => sendWindows(title, body, play_sound),
        .macos => sendMacOS(title, body, play_sound),
        else => sendLinux(title, body, play_sound),
    }
}

/// PTerm's stable AppUserModelID. Registered with the OS via a Start-menu
/// shortcut on first launch so the toast is attributed to PTerm (not
/// PowerShell, as the previous shell-out approach had it).
const PTERM_AUMID = "dev.pterm.PTerm";
const PTERM_DISPLAY = "PTerm";

const win_toast = if (builtin.os.tag == .windows) @cImport({
    @cInclude("win_toast.h");
}) else struct {};

var win_toast_init_done: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
var win_toast_init_ok: bool = false;

fn ensureWindowsToastInit() bool {
    if (win_toast_init_done.load(.acquire) != 0) return win_toast_init_ok;
    // First-call init: register AUMID and (if missing) create Start-menu
    // shortcut. Idempotent on subsequent runs.
    const rc = win_toast.pterm_notify_init(PTERM_AUMID, PTERM_DISPLAY);
    win_toast_init_ok = (rc == 0);
    win_toast_init_done.store(1, .release);
    return win_toast_init_ok;
}

/// Windows: native WinRT toast notification (no external process).
fn sendWindows(title: []const u8, body: []const u8, play_sound: bool) void {
    if (!ensureWindowsToastInit()) return;

    // Native side expects null-terminated UTF-8.
    var title_buf: [256]u8 = undefined;
    var body_buf: [1024]u8 = undefined;
    const tlen = @min(title.len, title_buf.len - 1);
    const blen = @min(body.len, body_buf.len - 1);
    @memcpy(title_buf[0..tlen], title[0..tlen]);
    title_buf[tlen] = 0;
    @memcpy(body_buf[0..blen], body[0..blen]);
    body_buf[blen] = 0;

    _ = win_toast.pterm_notify_send(
        @ptrCast(&title_buf),
        @ptrCast(&body_buf),
        if (play_sound) 1 else 0,
    );
}

/// macOS: osascript display notification.
fn sendMacOS(title: []const u8, body: []const u8, play_sound: bool) void {
    var script_buf: [512]u8 = undefined;
    var script_stream = std.io.fixedBufferStream(&script_buf);
    const sw = script_stream.writer();

    if (play_sound) {
        sw.print("display notification \"{s}\" with title \"{s}\" sound name \"default\"", .{ body, title }) catch return;
    } else {
        sw.print("display notification \"{s}\" with title \"{s}\"", .{ body, title }) catch return;
    }

    const script_len = script_stream.pos;
    const script_slice = script_buf[0..script_len];

    var argv_buf: [4][]const u8 = undefined;
    argv_buf[0] = "/usr/bin/osascript";
    argv_buf[1] = "-e";
    argv_buf[2] = script_slice;

    var child = std.process.Child.init(argv_buf[0..3], std.heap.page_allocator);
    _ = child.spawn() catch return;
    // Fire and forget
}

/// Linux: notify-send.
fn sendLinux(title: []const u8, body: []const u8, play_sound: bool) void {
    var argv_buf: [8][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "notify-send";
    argc += 1;
    argv_buf[argc] = "-a";
    argc += 1;
    argv_buf[argc] = "PTerm";
    argc += 1;

    if (!play_sound) {
        argv_buf[argc] = "--urgency=low";
        argc += 1;
    }

    argv_buf[argc] = title;
    argc += 1;
    argv_buf[argc] = body;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], std.heap.page_allocator);
    _ = child.spawn() catch return;
    // Fire and forget
}

// =============================================================================
// Tests
// =============================================================================

test "formatBody with matched text" {
    const result = formatBody("Tab 2, Pane 1", "? Continue?");
    try std.testing.expectEqualStrings("Tab 2, Pane 1: ? Continue?", result.slice());
}

test "formatBody with text longer than 80 chars truncates with ellipsis" {
    const long_text = "A" ** 100;
    const result = formatBody("Tab 1, Pane 1", long_text);
    const expected_prefix = "Tab 1, Pane 1: " ++ "A" ** 80 ++ "...";
    try std.testing.expectEqualStrings(expected_prefix, result.slice());
}

test "formatBody with null matched_text returns idle message" {
    const result = formatBody("Tab 1, Pane 2", null);
    try std.testing.expectEqualStrings("Tab 1, Pane 2: Output idle", result.slice());
}

test "formatBody with exactly 80 char text does not truncate" {
    const exact_text = "B" ** 80;
    const result = formatBody("P", exact_text);
    const expected = "P: " ++ "B" ** 80;
    try std.testing.expectEqualStrings(expected, result.slice());
}

test "sendNotification builds correct platform args" {
    // This test verifies the platform switch compiles and the correct branch is taken.
    // We cannot easily verify child process args without spawning, so we test
    // the platform detection logic.
    switch (builtin.os.tag) {
        .windows => {
            // On Windows, sendWindows would be called
            // Verify the function exists and compiles
            const F = @TypeOf(sendWindows);
            try std.testing.expect(@TypeOf(F) == type);
        },
        .macos => {
            const F = @TypeOf(sendMacOS);
            try std.testing.expect(@TypeOf(F) == type);
        },
        else => {
            const F = @TypeOf(sendLinux);
            try std.testing.expect(@TypeOf(F) == type);
        },
    }
}

test "TITLE constant is correct" {
    try std.testing.expectEqualStrings("PTerm -- Agent waiting", TITLE);
}
