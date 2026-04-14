/// E2E test harness for headless PTY-based testing.
///
/// Provides TestApp which wraps PTY open/spawn/read/write for platform tests
/// without requiring GPU or display. Shell auto-detection with category-based
/// failure handling (blocking vs warning-only per D-32, D-33, D-35).
const std = @import("std");
const builtin = @import("builtin");
const pty_mod = @import("pty");
const Pty = pty_mod.Pty;
const PtyConfig = pty_mod.PtyConfig;

/// Shell failure category (D-35).
/// Blocking shells cause test failure; warning-only shells log and continue.
pub const ShellCategory = enum {
    /// Default platform shells -- test failure = overall failure.
    blocking,
    /// Optional shells (nushell, fish) -- log warning on failure, don't fail.
    warning_only,
};

/// Shell information for E2E testing.
pub const ShellInfo = struct {
    name: []const u8,
    path: []const u8,
    category: ShellCategory,
    norc_flag: ?[]const u8,
};

/// Headless PTY-based test application.
/// Owns a PTY + child shell process for E2E testing without GPU/display.
pub const TestApp = struct {
    allocator: std.mem.Allocator,
    pty: Pty,
    shell_path_z: [*:0]const u8,

    /// Initialize TestApp: open PTY and spawn shell.
    pub fn init(allocator: std.mem.Allocator, shell_path: []const u8, shell_args: ?[*:null]const ?[*:0]const u8) !TestApp {
        var p = try Pty.init(allocator, .{ .cols = 80, .rows = 24 });
        errdefer p.deinit();

        // Convert shell_path to sentinel-terminated for spawn.
        // We need a null-terminated copy.
        const path_z = try allocator.dupeZ(u8, shell_path);
        const path_ptr: [*:0]const u8 = path_z.ptr;

        try p.spawn(path_ptr, shell_args, null);

        return .{
            .allocator = allocator,
            .pty = p,
            .shell_path_z = path_ptr,
        };
    }

    /// Send input bytes to the child process via PTY master.
    pub fn sendInput(self: *TestApp, input: []const u8) !void {
        var total: usize = 0;
        while (total < input.len) {
            const n = try self.pty.write(input[total..]);
            if (n == 0) return error.WriteFailed;
            total += n;
        }
    }

    /// Read output from PTY master with timeout.
    /// Returns bytes read, or 0 on timeout.
    pub fn readOutputTimeout(self: *TestApp, buf: []u8, timeout_ms: u64) !usize {
        if (comptime builtin.os.tag == .windows) {
            return windowsReadWithTimeout(self, buf, timeout_ms);
        } else {
            return posixReadWithTimeout(self, buf, timeout_ms);
        }
    }

    /// Repeatedly read output until needle is found or timeout expires.
    /// Returns true if needle was found.
    pub fn expectOutput(self: *TestApp, needle: []const u8, timeout_ms: u64) !bool {
        var accumulated: [16384]u8 = undefined;
        var total: usize = 0;
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

        while (std.time.milliTimestamp() < deadline) {
            const remaining = accumulated.len - total;
            if (remaining == 0) {
                // Buffer full, shift down keeping last half
                const half = accumulated.len / 2;
                @memcpy(accumulated[0..half], accumulated[half..accumulated.len]);
                total = half;
            }
            const n = self.readOutputTimeout(accumulated[total..], 500) catch |err| {
                if (err == error.ReadFailed) {
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            total += n;
            if (std.mem.indexOf(u8, accumulated[0..total], needle) != null) return true;
            if (n == 0) {
                std.Thread.sleep(50 * std.time.ns_per_ms);
            }
        }
        return false;
    }

    /// Clean up PTY resources and kill child if still running.
    pub fn deinit(self: *TestApp) void {
        self.pty.deinit();
        // Free the duped path string
        const slice = std.mem.span(self.shell_path_z);
        self.allocator.free(slice[0 .. slice.len + 1]);
    }

    // -- Platform-specific read helpers --

    fn posixReadWithTimeout(self: *TestApp, buf: []u8, timeout_ms: u64) !usize {
        if (comptime builtin.os.tag == .windows) unreachable;
        // Use poll() for timeout on Unix
        const c = @cImport({
            @cInclude("poll.h");
        });
        var fds = [1]c.struct_pollfd{.{
            .fd = self.pty.master_fd,
            .events = c.POLLIN,
            .revents = 0,
        }};
        const poll_result = c.poll(&fds, 1, @intCast(timeout_ms));
        if (poll_result <= 0) return 0; // timeout or error
        if (fds[0].revents & c.POLLIN != 0) {
            return try self.pty.read(buf);
        }
        return 0;
    }

    fn windowsReadWithTimeout(self: *TestApp, buf: []u8, timeout_ms: u64) !usize {
        if (comptime builtin.os.tag != .windows) unreachable;
        // PeekNamedPipe + ReadFile with timeout loop
        const PeekNamedPipe = @extern(*const fn (
            std.os.windows.HANDLE,
            ?[*]u8,
            std.os.windows.DWORD,
            ?*std.os.windows.DWORD,
            ?*std.os.windows.DWORD,
            ?*std.os.windows.DWORD,
        ) callconv(.c) std.os.windows.BOOL, .{ .name = "PeekNamedPipe", .library_name = "kernel32" });

        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (std.time.milliTimestamp() < deadline) {
            var avail: std.os.windows.DWORD = 0;
            const peek_ok = PeekNamedPipe(self.pty.output_read, null, 0, null, &avail, null);
            if (peek_ok != 0 and avail > 0) {
                return try self.pty.read(buf);
            }
            if (peek_ok == 0) return error.ReadFailed;
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        return 0; // timeout
    }
};

/// Auto-detect available shells on the current system (D-32, D-33).
/// Returns shells that exist, with category (blocking vs warning_only per D-35).
pub fn availableShells(allocator: std.mem.Allocator) ![]ShellInfo {
    var shells: std.ArrayList(ShellInfo) = .empty;
    errdefer shells.deinit(allocator);

    if (comptime builtin.os.tag == .windows) {
        tryAddShell(&shells, allocator, "powershell", "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", .blocking, "-NoProfile");
        tryAddShell(&shells, allocator, "cmd", "C:\\Windows\\System32\\cmd.exe", .blocking, null);
        tryAddShellFromPath(&shells, allocator, "nu", .warning_only, null);
    } else if (comptime builtin.os.tag == .macos) {
        tryAddShell(&shells, allocator, "zsh", "/bin/zsh", .blocking, "--no-rcs");
        tryAddShell(&shells, allocator, "bash", "/bin/bash", .blocking, "--norc");
        tryAddShellFromPath(&shells, allocator, "nu", .warning_only, null);
        tryAddShellFromPath(&shells, allocator, "fish", .warning_only, "--no-config");
    } else {
        // Linux
        tryAddShell(&shells, allocator, "bash", "/bin/bash", .blocking, "--norc");
        tryAddShell(&shells, allocator, "zsh", "/usr/bin/zsh", .blocking, "--no-rcs");
        tryAddShellFromPath(&shells, allocator, "nu", .warning_only, null);
        tryAddShellFromPath(&shells, allocator, "fish", .warning_only, "--no-config");
    }

    return shells.toOwnedSlice(allocator);
}

/// Check if shell exists at a fixed path and add to list.
fn tryAddShell(
    shells: *std.ArrayList(ShellInfo),
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,
    category: ShellCategory,
    norc_flag: ?[]const u8,
) void {
    std.fs.cwd().access(path, .{}) catch return;
    shells.append(allocator, .{
        .name = name,
        .path = path,
        .category = category,
        .norc_flag = norc_flag,
    }) catch {};
}

/// Find shell by name in PATH and add to list.
fn tryAddShellFromPath(
    shells: *std.ArrayList(ShellInfo),
    allocator: std.mem.Allocator,
    name: []const u8,
    category: ShellCategory,
    norc_flag: ?[]const u8,
) void {
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch return;
    defer allocator.free(path_env);

    const sep = if (comptime builtin.os.tag == .windows) ';' else ':';
    var it = std.mem.splitScalar(u8, path_env, sep);

    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const exe_name = if (comptime builtin.os.tag == .windows)
            std.fmt.allocPrint(allocator, "{s}\\{s}.exe", .{ dir, name }) catch continue
        else
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name }) catch continue;

        std.fs.cwd().access(exe_name, .{}) catch {
            allocator.free(exe_name);
            continue;
        };

        // Found it -- exe_name is heap-allocated, ownership transfers to the list
        shells.append(allocator, .{
            .name = name,
            .path = exe_name,
            .category = category,
            .norc_flag = norc_flag,
        }) catch {
            allocator.free(exe_name);
        };
        return;
    }
}

/// Get the default shell path for the current platform.
pub fn defaultShellPath() []const u8 {
    if (comptime builtin.os.tag == .windows) {
        return "cmd.exe";
    } else {
        return "/bin/sh";
    }
}
