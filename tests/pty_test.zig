const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const pty_mod = @import("platform_pty");
const Pty = pty_mod.Pty;
const PtyConfig = pty_mod.PtyConfig;
const shell_mod = @import("platform_shell");
const ShellConfig = shell_mod.ShellConfig;
const mailbox_mod = @import("mailbox");
const reader_mod = @import("reader");
const PtyReader = reader_mod.PtyReader;

// ============================================================================
// Helper: non-blocking peek+read for ConPTY (avoids ReadFile blocking)
// ============================================================================

const PeekNamedPipeFn = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn PeekNamedPipe(
        hNamedPipe: std.os.windows.HANDLE,
        lpBuffer: ?[*]u8,
        nBufferSize: std.os.windows.DWORD,
        lpBytesRead: ?*std.os.windows.DWORD,
        lpTotalBytesAvail: ?*std.os.windows.DWORD,
        lpBytesLeftThisMessage: ?*std.os.windows.DWORD,
    ) callconv(.c) std.os.windows.BOOL;
}.PeekNamedPipe else void;

/// Read from PTY with timeout. On Windows, uses PeekNamedPipe to avoid
/// blocking indefinitely on ReadFile.
fn peekAndRead(p: *Pty, buf: []u8, timeout_ms: u64) !usize {
    if (comptime builtin.os.tag == .windows) {
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (std.time.milliTimestamp() < deadline) {
            var avail: std.os.windows.DWORD = 0;
            const peek_ok = PeekNamedPipeFn(p.output_read, null, 0, null, &avail, null);
            if (peek_ok != 0 and avail > 0) {
                return try p.read(buf);
            }
            if (peek_ok == 0) return error.ReadFailed;
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        return 0; // timeout
    } else {
        return try p.read(buf);
    }
}

// ============================================================================
// Shell detection tests
// ============================================================================

test "shell detection returns valid shell" {
    const shell = shell_mod.detectShell();
    const path_slice = std.mem.span(shell.path);
    try testing.expect(path_slice.len > 0);
    try testing.expect(shell.name.len > 0);
}

test "known shells list is non-empty" {
    const shells = shell_mod.getAvailableShells();
    try testing.expect(shells.len > 0);
    for (shells) |s| {
        const path_slice = std.mem.span(s.path);
        try testing.expect(path_slice.len > 0);
        try testing.expect(s.name.len > 0);
    }
}

// ============================================================================
// PTY spawn and I/O tests
// ============================================================================

test "pty spawn and read output" {
    var p = try Pty.init(testing.allocator, .{ .cols = 80, .rows = 24 });

    const shell_path: [*:0]const u8 = if (comptime builtin.os.tag == .windows)
        "cmd.exe"
    else
        "/bin/sh";
    try p.spawn(shell_path, null, null);

    const pid = p.getChildPid();
    try testing.expect(pid != null);

    // Read output -- ConPTY sends VT escape sequences when shell starts.
    // On Windows within another terminal, we get VT control sequences
    // (e.g., mode set sequences) rather than text content.
    var buf: [4096]u8 = undefined;
    const n = try peekAndRead(&p, &buf, 5000);
    try testing.expect(n > 0);

    p.deinit();
}

test "pty write and read roundtrip" {
    var p = try Pty.init(testing.allocator, .{ .cols = 80, .rows = 24 });

    const shell_path: [*:0]const u8 = if (comptime builtin.os.tag == .windows)
        "cmd.exe"
    else
        "/bin/sh";
    try p.spawn(shell_path, null, null);

    // Read initial output
    var initial_buf: [8192]u8 = undefined;
    _ = try peekAndRead(&p, &initial_buf, 5000);

    // Write echo command -- verifies the write path works
    const cmd = if (comptime builtin.os.tag == .windows)
        "echo hello\r\n"
    else
        "echo hello\n";
    const written = try p.write(cmd);
    // Verify we wrote all bytes
    try testing.expect(written == cmd.len);

    // On Windows within another terminal (nested ConPTY), the actual text
    // output goes to the parent console, not the pipe. The pipe only
    // carries VT escape sequences. In production (when PTerm IS the
    // terminal), all output goes through the pipe.
    // For now, we verify that write succeeded and the PTY is still alive.
    if (comptime builtin.os.tag != .windows) {
        // On Unix, we can verify the echo response
        var buf: [8192]u8 = undefined;
        var total: usize = 0;
        var attempts: usize = 0;
        while (attempts < 20) : (attempts += 1) {
            const n = try p.read(buf[total..]);
            total += n;
            if (total > 0 and std.mem.indexOf(u8, buf[0..total], "hello") != null) break;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        try testing.expect(std.mem.indexOf(u8, buf[0..total], "hello") != null);
    }

    p.deinit();
}

test "pty resize" {
    var p = try Pty.init(testing.allocator, .{ .cols = 80, .rows = 24 });

    const shell_path: [*:0]const u8 = if (comptime builtin.os.tag == .windows)
        "cmd.exe"
    else
        "/bin/sh";
    try p.spawn(shell_path, null, null);

    // Wait for shell to start
    var buf: [4096]u8 = undefined;
    _ = try peekAndRead(&p, &buf, 3000);

    // Resize should not error
    try p.resize(120, 40);

    // Drain any resize output
    _ = peekAndRead(&p, &buf, 1000) catch {};

    p.deinit();
}

test "pty spawn default shell" {
    var p = try Pty.init(testing.allocator, .{ .cols = 80, .rows = 24 });

    const shell_path: [*:0]const u8 = if (comptime builtin.os.tag == .windows)
        "cmd.exe"
    else blk: {
        const shell = shell_mod.detectShell();
        break :blk shell.path;
    };
    try p.spawn(shell_path, null, null);

    // Should be able to read at least 1 byte (VT sequences on Windows)
    var buf: [4096]u8 = undefined;
    const n = try peekAndRead(&p, &buf, 5000);
    try testing.expect(n > 0);

    p.deinit();
}

// ============================================================================
// Mailbox tests (SPSC ring buffer)
// ============================================================================

test "mailbox push and pop" {
    const Mailbox = mailbox_mod.Mailbox(256);
    var mbox = Mailbox{};

    // Push 100 bytes
    const data = "a]" ** 50; // 100 chars
    const pushed = mbox.push(data);
    try testing.expectEqual(@as(usize, 100), pushed);

    // Pop them back
    var out: [256]u8 = undefined;
    const popped = mbox.pop(&out);
    try testing.expectEqual(@as(usize, 100), popped);
    try testing.expectEqualSlices(u8, data, out[0..100]);
}

test "mailbox wraparound" {
    const Mailbox = mailbox_mod.Mailbox(64);
    var mbox = Mailbox{};

    // Fill near capacity (63 bytes max in 64-capacity buffer)
    const fill = [_]u8{'X'} ** 60;
    const pushed1 = mbox.push(&fill);
    try testing.expectEqual(@as(usize, 60), pushed1);

    // Pop 40 bytes to free space
    var out: [64]u8 = undefined;
    const popped1 = mbox.pop(out[0..40]);
    try testing.expectEqual(@as(usize, 40), popped1);

    // Push 30 more bytes (should wrap around the end of buffer)
    const more = [_]u8{'Y'} ** 30;
    const pushed2 = mbox.push(&more);
    try testing.expectEqual(@as(usize, 30), pushed2);

    // Pop everything remaining (20 X's + 30 Y's = 50 bytes)
    var out2: [64]u8 = undefined;
    const popped2 = mbox.pop(&out2);
    try testing.expectEqual(@as(usize, 50), popped2);

    // First 20 should be 'X', next 30 should be 'Y'
    for (out2[0..20]) |b| try testing.expectEqual(@as(u8, 'X'), b);
    for (out2[20..50]) |b| try testing.expectEqual(@as(u8, 'Y'), b);
}

test "mailbox full returns 0" {
    const Mailbox = mailbox_mod.Mailbox(16);
    var mbox = Mailbox{};

    // Fill to capacity (15 bytes in 16-capacity buffer)
    const fill = [_]u8{'Z'} ** 15;
    const pushed = mbox.push(&fill);
    try testing.expectEqual(@as(usize, 15), pushed);

    // Try to push more -- should return 0
    const extra = [_]u8{'Q'} ** 5;
    const pushed2 = mbox.push(&extra);
    try testing.expectEqual(@as(usize, 0), pushed2);

    // freeSpace should be 0
    try testing.expectEqual(@as(usize, 0), mbox.freeSpace());

    // available should be 15
    try testing.expectEqual(@as(usize, 15), mbox.available());
}

test "pty reader thread delivers bytes" {
    var p = try Pty.init(testing.allocator, .{ .cols = 80, .rows = 24 });

    const shell_path: [*:0]const u8 = if (comptime builtin.os.tag == .windows)
        "cmd.exe"
    else
        "/bin/sh";
    try p.spawn(shell_path, null, null);

    // Create mailbox and reader
    const Mailbox = mailbox_mod.Mailbox(65536);
    var mbox = Mailbox{};
    var reader = PtyReader.init(&p, &mbox);

    // Start the reader thread
    try reader.start();

    // Wait for data to arrive in the mailbox
    const deadline = std.time.milliTimestamp() + 5000;
    while (std.time.milliTimestamp() < deadline) {
        if (mbox.available() > 0) break;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    // Should have received some bytes from the shell
    try testing.expect(mbox.available() > 0);

    // Pop and verify non-empty
    var buf: [4096]u8 = undefined;
    const n = mbox.pop(&buf);
    try testing.expect(n > 0);

    // Stop the reader
    reader.stop();
    p.deinit();
}

test "pty reader stop" {
    var p = try Pty.init(testing.allocator, .{ .cols = 80, .rows = 24 });

    const shell_path: [*:0]const u8 = if (comptime builtin.os.tag == .windows)
        "cmd.exe"
    else
        "/bin/sh";
    try p.spawn(shell_path, null, null);

    const Mailbox = mailbox_mod.Mailbox(65536);
    var mbox = Mailbox{};
    var reader = PtyReader.init(&p, &mbox);

    // Start then immediately stop
    try reader.start();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Stop should join the thread cleanly
    reader.stop();

    // Thread should be null after stop
    try testing.expect(reader.thread == null);

    p.deinit();
}
