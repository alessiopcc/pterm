/// Cross-platform system beep.
///
/// Windows: MessageBeep via Win32 API.
/// macOS/Linux: Write BEL byte to /dev/tty.
const builtin = @import("builtin");
const std = @import("std");

pub fn beep() void {
    switch (builtin.os.tag) {
        .windows => {
            // MessageBeep(0xFFFFFFFF) plays the default system beep sound.
            // Accessed via extern C declaration since Zig std doesn't wrap this.
            _ = MessageBeep(0xFFFFFFFF);
        },
        else => {
            // Write BEL (0x07) to /dev/tty to trigger system bell on macOS/Linux.
            if (std.fs.openFileAbsolute("/dev/tty", .{ .mode = .write_only })) |tty| {
                defer tty.close();
                _ = tty.write("\x07") catch {};
            } else |_| {}
        },
    }
}

// Windows extern: user32.dll MessageBeep
extern "user32" fn MessageBeep(uType: u32) callconv(.c) i32;

// Provide a testable check for platform command.
pub fn platformName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "MessageBeep",
        .macos => "BEL-to-tty",
        .linux => "BEL-to-tty",
        else => "BEL-to-tty",
    };
}

test "platformName returns expected value" {
    const name = platformName();
    try std.testing.expect(name.len > 0);
    // Platform-specific: on Windows "MessageBeep", others "BEL-to-tty"
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("MessageBeep", name);
    } else {
        try std.testing.expectEqualStrings("BEL-to-tty", name);
    }
}
