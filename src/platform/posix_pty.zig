// Unix PTY Backend via forkpty (D-08)
//
// This backend uses POSIX forkpty() to create a pseudo-terminal and spawn
// a child process. Resize signaling uses ioctl(TIOCSWINSZ) which causes
// the kernel to send SIGWINCH to the child process automatically (D-10).
//
// This file only compiles on Linux and macOS targets.

const std = @import("std");
const posix = std.posix;

const builtin = @import("builtin");

const c = @cImport({
    // forkpty lives in <util.h> on macOS, <pty.h> on Linux.
    if (builtin.os.tag == .macos) {
        @cInclude("util.h");
    } else {
        @cInclude("pty.h");
    }
    @cInclude("unistd.h"); // execvp, close, read, write
    @cInclude("stdlib.h"); // setenv
    @cInclude("sys/ioctl.h"); // ioctl, TIOCSWINSZ
    @cInclude("sys/wait.h"); // waitpid, WNOHANG
    @cInclude("signal.h"); // kill
});

pub const PosixPtyError = error{
    ForkFailed,
    ExecFailed,
    ReadFailed,
    WriteFailed,
    ResizeFailed,
    CloseFailed,
};

/// Unix PTY backend using forkpty.
pub const PosixPty = struct {
    master_fd: c_int,
    child_pid: c.pid_t,
    config: @import("pty.zig").PtyConfig,

    pub fn init(_: std.mem.Allocator, config: @import("pty.zig").PtyConfig) !PosixPty {
        return PosixPty{
            .master_fd = -1,
            .child_pid = -1,
            .config = config,
        };
    }

    /// Spawn a child process in a new pseudo-terminal via forkpty.
    pub fn spawn(self: *PosixPty, shell_path: [*:0]const u8, args: ?[*:null]const ?[*:0]const u8, working_dir: ?[*:0]const u8) PosixPtyError!void {
        var ws: c.struct_winsize = .{
            .ws_col = self.config.cols,
            .ws_row = self.config.rows,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        var master_fd: c_int = undefined;
        const pid = c.forkpty(&master_fd, null, null, &ws);

        if (pid < 0) {
            return PosixPtyError.ForkFailed;
        }

        if (pid == 0) {
            // Child process -- exec the shell
            const default_args = [_:null]?[*:0]const u8{shell_path};
            const exec_args = if (args) |a| a else &default_args;

            // Change to working directory if specified (D-23: per-pane CWD)
            if (working_dir) |wd| {
                _ = c.chdir(wd);
            }

            // Set TERM and COLORTERM for proper terminal capability detection (D-48)
            _ = c.setenv("TERM", "xterm-256color", 1);
            _ = c.setenv("COLORTERM", "truecolor", 1);

            // Set up environment if provided
            if (self.config.env) |env| {
                _ = c.execve(shell_path, @ptrCast(exec_args), @ptrCast(env));
            } else {
                _ = c.execvp(shell_path, @ptrCast(exec_args));
            }

            // If exec returns, it failed
            std.process.exit(127);
        }

        // Parent process
        self.master_fd = master_fd;
        self.child_pid = pid;
    }

    /// Read bytes from the child process output.
    /// Returns number of bytes read. Returns 0 on EAGAIN (non-blocking).
    pub fn read(self: *PosixPty, buf: []u8) PosixPtyError!usize {
        const result = c.read(self.master_fd, buf.ptr, buf.len);
        if (result < 0) {
            const err = std.c._errno().*;
            if (err == @intFromEnum(std.c.E.AGAIN) or err == @intFromEnum(std.c.E.INTR)) {
                return 0;
            }
            return PosixPtyError.ReadFailed;
        }
        return @intCast(result);
    }

    /// Write bytes to the child process input.
    /// Returns number of bytes written.
    pub fn write(self: *PosixPty, data: []const u8) PosixPtyError!usize {
        const result = c.write(self.master_fd, data.ptr, data.len);
        if (result < 0) {
            return PosixPtyError.WriteFailed;
        }
        return @intCast(result);
    }

    /// Resize the pseudo-terminal (D-10).
    /// The kernel sends SIGWINCH to the child process automatically.
    pub fn resize(self: *PosixPty, cols: u16, rows: u16) PosixPtyError!void {
        var ws: c.struct_winsize = .{
            .ws_col = cols,
            .ws_row = rows,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        const result = c.ioctl(self.master_fd, c.TIOCSWINSZ, &ws);
        if (result < 0) {
            return PosixPtyError.ResizeFailed;
        }
    }

    /// Get the child process ID for management.
    pub fn getChildPid(self: *const PosixPty) ?i32 {
        if (self.child_pid <= 0) return null;
        return @intCast(self.child_pid);
    }

    /// Clean up PTY resources.
    pub fn deinit(self: *PosixPty) void {
        if (self.master_fd >= 0) {
            _ = c.close(self.master_fd);
            self.master_fd = -1;
        }
        if (self.child_pid > 0) {
            // Try non-blocking wait first
            var status: c_int = 0;
            const waited = c.waitpid(self.child_pid, &status, c.WNOHANG);
            if (waited == 0) {
                // Child still running, send SIGTERM and wait briefly
                _ = c.kill(self.child_pid, c.SIGTERM);
                _ = c.usleep(200_000); // 200ms grace period
                const still_running = c.waitpid(self.child_pid, &status, c.WNOHANG);
                if (still_running == 0) {
                    // Child ignored SIGTERM, force kill
                    _ = c.kill(self.child_pid, c.SIGKILL);
                    _ = c.waitpid(self.child_pid, &status, 0);
                }
            }
            self.child_pid = -1;
        }
    }
};
