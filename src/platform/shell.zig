// Shell Detection and Spawn Configuration (D-09)
//
// Detects the user's default shell on Unix (via $SHELL) and Windows
// (via $COMSPEC, with PowerShell/cmd.exe fallbacks).

const std = @import("std");
const builtin = @import("builtin");

/// Configuration for launching a shell process.
pub const ShellConfig = struct {
    path: [*:0]const u8,
    args: ?[*:null]const ?[*:0]const u8 = null,
    name: []const u8,
};

/// Detect the user's default shell.
/// On Unix: checks $SHELL env var, falls back to /bin/sh.
/// On Windows: checks $COMSPEC, falls back to powershell.exe, then cmd.exe.
pub fn detectShell() ShellConfig {
    if (comptime builtin.os.tag == .windows) {
        return detectWindowsShell();
    } else {
        return detectUnixShell();
    }
}

fn detectUnixShell() ShellConfig {
    if (std.posix.getenv("SHELL")) |shell_env| {
        // Find the shell name (last component of path)
        const name = extractShellName(shell_env);
        // We need a sentinel-terminated pointer; the env var is already null-terminated in C
        return ShellConfig{
            .path = @ptrCast(shell_env.ptr),
            .args = null,
            .name = name,
        };
    }
    return ShellConfig{
        .path = "/bin/sh",
        .args = null,
        .name = "sh",
    };
}

fn detectWindowsShell() ShellConfig {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "COMSPEC") catch null) |_| {
        // COMSPEC is typically C:\Windows\system32\cmd.exe
        // But we prefer PowerShell if available
        return ShellConfig{
            .path = "powershell.exe",
            .args = null,
            .name = "powershell",
        };
    }
    return ShellConfig{
        .path = "cmd.exe",
        .args = null,
        .name = "cmd",
    };
}

/// Extract shell name from a path (e.g., "/bin/bash" -> "bash").
fn extractShellName(path: []const u8) []const u8 {
    const sep = comptime if (builtin.os.tag == .windows) '\\' else '/';
    if (std.mem.lastIndexOfScalar(u8, path, sep)) |idx| {
        return path[idx + 1 ..];
    }
    return path;
}

/// Known shells for testing across platforms (D-09).
pub const known_shells = if (builtin.os.tag == .windows)
    [_]ShellConfig{
        .{ .path = "powershell.exe", .args = null, .name = "powershell" },
        .{ .path = "cmd.exe", .args = null, .name = "cmd" },
    }
else
    [_]ShellConfig{
        .{ .path = "/bin/bash", .args = null, .name = "bash" },
        .{ .path = "/bin/zsh", .args = null, .name = "zsh" },
        .{ .path = "/usr/bin/fish", .args = null, .name = "fish" },
        .{ .path = "/usr/bin/nu", .args = null, .name = "nushell" },
    };

/// Get list of available known shells on the current platform.
pub fn getAvailableShells() []const ShellConfig {
    return &known_shells;
}
