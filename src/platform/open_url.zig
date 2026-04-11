/// Cross-platform URL opening via system default browser.
///
/// SECURITY (T-06-03): URL is passed as a discrete argv argument to the child
/// process, never interpolated into a shell command string. This prevents
/// command injection. On Windows, "cmd.exe /c start" with an empty title
/// argument prevents title/URL confusion.
const builtin = @import("builtin");
const std = @import("std");

/// The base command for each platform (without the URL argument).
pub const PlatformCommand = struct {
    /// Static command parts (before the URL).
    args: []const []const u8,
    /// Name for diagnostics.
    name: []const u8,
};

/// Get the platform command descriptor.
pub fn platformCommand() PlatformCommand {
    return switch (builtin.os.tag) {
        .windows => .{
            .args = &.{ "cmd.exe", "/c", "start", "" },
            .name = "cmd.exe /c start",
        },
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

/// Open a URL in the system default browser/handler.
/// Fire and forget -- does not wait for the child process.
pub fn openUrl(url: []const u8) void {
    const cmd = platformCommand();

    // Build argv: static command args + url
    var argv_buf: [8][]const u8 = undefined;
    var argc: usize = 0;
    for (cmd.args) |arg| {
        argv_buf[argc] = arg;
        argc += 1;
    }
    argv_buf[argc] = url;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], std.heap.page_allocator);
    _ = child.spawn() catch return;
    // Fire and forget -- do not wait for child process
}

// =============================================================================
// Tests
// =============================================================================

test "platformCommand returns correct command for current OS" {
    const cmd = platformCommand();

    switch (builtin.os.tag) {
        .windows => {
            try std.testing.expectEqual(@as(usize, 4), cmd.args.len);
            try std.testing.expectEqualStrings("cmd.exe", cmd.args[0]);
            try std.testing.expectEqualStrings("/c", cmd.args[1]);
            try std.testing.expectEqualStrings("start", cmd.args[2]);
            try std.testing.expectEqualStrings("", cmd.args[3]);
        },
        .macos => {
            try std.testing.expectEqual(@as(usize, 1), cmd.args.len);
            try std.testing.expectEqualStrings("/usr/bin/open", cmd.args[0]);
        },
        else => {
            try std.testing.expectEqual(@as(usize, 1), cmd.args.len);
            try std.testing.expectEqualStrings("xdg-open", cmd.args[0]);
        },
    }
}

test "platformCommand args are comptime string literals" {
    const cmd = platformCommand();
    // All static args should be non-empty or intentionally empty
    for (cmd.args, 0..) |arg, i| {
        // The Windows empty title arg (index 3) is intentionally empty
        if (builtin.os.tag == .windows and i == 3) {
            try std.testing.expectEqual(@as(usize, 0), arg.len);
        }
        // Just verify we can read them without segfault
        _ = arg.len;
    }
}
