//! Process-wide `std.Io` plus thin helpers for the std APIs that moved behind
//! it in Zig 0.16+ (clocks, sleep, mutexes, environment).
//!
//! `main` installs the runtime's `Io` and environment via `init`. Test binaries
//! use the test runner's `std.testing.io` / `std.testing.environ`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub var io: Io = if (builtin.is_test) std.testing.io else Io.Threaded.global_single_threaded.io();

/// The process environment. Windows reads the live process block; on POSIX
/// it is empty until `init` (falls back to libc `getenv` when available).
/// Ignored in test builds in favour of `std.testing.environ`.
pub var environ: std.process.Environ = if (builtin.os.tag == .windows)
    .{ .block = .global }
else
    .empty;

pub fn init(process_init: std.process.Init) void {
    io = process_init.io;
    environ = process_init.minimal.environ;
}

/// Monotonic nanoseconds since an unspecified point; use for intervals only.
pub fn nanoTimestamp() i128 {
    return Io.Clock.awake.now(io).toNanoseconds();
}

/// Monotonic milliseconds since an unspecified point; use for intervals only.
pub fn milliTimestamp() i64 {
    return Io.Clock.awake.now(io).toMilliseconds();
}

/// Wall-clock seconds since the Unix epoch.
pub fn timestamp() i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).toNanoseconds(), std.time.ns_per_s));
}

pub fn sleep(ns: u64) void {
    io.sleep(.fromNanoseconds(@intCast(ns)), .awake) catch {};
}

/// Drop-in for the removed `std.Thread.Mutex` (default-initialised, no `Io`
/// argument at call sites).
pub const Mutex = struct {
    inner: Io.Mutex = .init,

    pub fn lock(m: *Mutex) void {
        m.inner.lockUncancelable(io);
    }

    pub fn unlock(m: *Mutex) void {
        m.inner.unlock(io);
    }

    pub fn tryLock(m: *Mutex) bool {
        return m.inner.tryLock();
    }
};

fn currentEnviron() std.process.Environ {
    return if (builtin.is_test) std.testing.environ else environ;
}

pub const GetEnvVarError = error{ OutOfMemory, EnvironmentVariableMissing };

/// Caller owns the returned memory. Avoids building a full environment map,
/// so it is safe to call with small fixed-buffer allocators (crash handler).
pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) GetEnvVarError![]u8 {
    if (builtin.os.tag == .windows) {
        var key_w: [256:0]u16 = undefined;
        const n = std.unicode.wtf8ToWtf16Le(&key_w, key) catch return error.EnvironmentVariableMissing;
        if (n >= key_w.len) return error.EnvironmentVariableMissing;
        key_w[n] = 0;
        const value = currentEnviron().getWindows(key_w[0..n :0]) orelse return error.EnvironmentVariableMissing;
        return std.unicode.wtf16LeToWtf8Alloc(allocator, value);
    }
    if (currentEnviron().getPosix(key)) |value| return allocator.dupe(u8, value);
    if (builtin.link_libc) {
        var key_z: [256:0]u8 = undefined;
        if (key.len >= key_z.len) return error.EnvironmentVariableMissing;
        @memcpy(key_z[0..key.len], key);
        key_z[key.len] = 0;
        if (std.c.getenv(&key_z)) |value| return allocator.dupe(u8, std.mem.span(value));
    }
    return error.EnvironmentVariableMissing;
}

/// Read the rest of `file` into an allocator-owned slice (replacement for the
/// removed `File.readToEndAlloc`).
pub fn readToEndAlloc(file: std.Io.File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var r = file.readerStreaming(io, &.{});
    return r.interface.allocRemaining(allocator, .limited(max_bytes)) catch |err| switch (err) {
        error.ReadFailed => r.err orelse error.ReadFailed,
        else => |e| e,
    };
}
