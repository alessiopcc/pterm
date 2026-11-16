/// Cross-platform URL opening via system default browser.
///
/// SECURITY: only http and https URLs are opened. file:// is refused because
/// opening a file URL runs the file when it is a program. On Windows the URL
/// goes straight to ShellExecuteW, never through cmd.exe: cmd parses `&`, `|`
/// and `^` inside an argument, so a crafted URL could run commands. On macOS
/// and Linux the URL is a discrete argv argument, never part of a shell
/// command string.
const builtin = @import("builtin");
const std = @import("std");
const pio = @import("pio");

/// The base command for each platform (without the URL argument).
/// Windows has none: it uses ShellExecuteW.
pub const PlatformCommand = struct {
    /// Static command parts (before the URL).
    args: []const []const u8,
    /// Name for diagnostics.
    name: []const u8,
};

/// Get the platform command descriptor (macOS and Linux).
pub fn platformCommand() PlatformCommand {
    return switch (builtin.os.tag) {
        .macos => .{
            .args = &.{"/usr/bin/open"},
            .name = "/usr/bin/open",
        },
        else => .{
            .args = &.{"xdg-open"},
            .name = "xdg-open",
        },
    };
}

/// Whether `url` may be opened: an http or https URL with no control
/// characters (a newline or NUL could split or cut it on the way out).
pub fn isOpenable(url: []const u8) bool {
    const schemes = [_][]const u8{ "http://", "https://" };
    var ok = false;
    for (schemes) |s| {
        if (url.len > s.len and std.ascii.startsWithIgnoreCase(url, s)) ok = true;
    }
    if (!ok) return false;
    for (url) |c| {
        if (c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

const SW_SHOWNORMAL: c_int = 1;
extern "shell32" fn ShellExecuteW(
    hwnd: ?*anyopaque,
    lpOperation: ?[*:0]const u16,
    lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16,
    lpDirectory: ?[*:0]const u16,
    nShowCmd: c_int,
) callconv(.winapi) ?*anyopaque;

/// Open a URL in the system default browser/handler.
/// Fire and forget -- does not wait for the child process.
pub fn openUrl(url: []const u8) void {
    if (!isOpenable(url)) return;

    if (builtin.os.tag == .windows) {
        var wbuf: [4096]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(wbuf[0 .. wbuf.len - 1], url) catch return;
        wbuf[n] = 0;
        const open_w = std.unicode.utf8ToUtf16LeStringLiteral("open");
        _ = ShellExecuteW(null, open_w, wbuf[0..n :0], null, null, SW_SHOWNORMAL);
        return;
    }

    const cmd = platformCommand();
    var argv_buf: [8][]const u8 = undefined;
    var argc: usize = 0;
    for (cmd.args) |arg| {
        argv_buf[argc] = arg;
        argc += 1;
    }
    argv_buf[argc] = url;
    argc += 1;

    _ = std.process.spawn(pio.io, .{ .argv = argv_buf[0..argc] }) catch return;
    // Fire and forget -- do not wait for child process
}

// =============================================================================
// Tests
// =============================================================================

test "platformCommand returns correct command for current OS" {
    const cmd = platformCommand();
    try std.testing.expectEqual(@as(usize, 1), cmd.args.len);
    switch (builtin.os.tag) {
        .macos => try std.testing.expectEqualStrings("/usr/bin/open", cmd.args[0]),
        else => try std.testing.expectEqualStrings("xdg-open", cmd.args[0]),
    }
}

test "isOpenable accepts web URLs" {
    try std.testing.expect(isOpenable("https://example.com/a?b=1&c=2"));
    try std.testing.expect(isOpenable("HTTP://example.com"));
}

test "isOpenable rejects other schemes and control characters" {
    try std.testing.expect(!isOpenable("https://"));
    try std.testing.expect(!isOpenable("javascript:alert(1)"));
    try std.testing.expect(!isOpenable("ms-settings:"));
    try std.testing.expect(!isOpenable("file:///C:/Users/x/Downloads/setup.exe"));
    try std.testing.expect(!isOpenable("C:\\Windows\\System32\\calc.exe"));
    try std.testing.expect(!isOpenable("https://x\n/y"));
    try std.testing.expect(!isOpenable("https://x\x00y"));
}
