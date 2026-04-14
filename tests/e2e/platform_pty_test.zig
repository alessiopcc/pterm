/// E2E tests: Platform-specific PTY verification.
///
/// On Windows: verifies ConPTY creation and resize.
/// On Unix: verifies posix PTY creation and resize.
/// Uses builtin.os.tag for conditional compilation.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const pty_mod = @import("pty");
const Pty = pty_mod.Pty;
const PtyConfig = pty_mod.PtyConfig;

test "PTY creation succeeds on current platform" {
    var p = try Pty.init(testing.allocator, .{ .cols = 80, .rows = 24 });

    const shell_path: [*:0]const u8 = if (comptime builtin.os.tag == .windows)
        "cmd.exe"
    else
        "/bin/sh";
    try p.spawn(shell_path, null, null);

    // Verify child process was created
    const pid = p.getChildPid();
    try testing.expect(pid != null);

    p.deinit();
}

test "PTY resize works on current platform" {
    var p = try Pty.init(testing.allocator, .{ .cols = 80, .rows = 24 });

    const shell_path: [*:0]const u8 = if (comptime builtin.os.tag == .windows)
        "cmd.exe"
    else
        "/bin/sh";
    try p.spawn(shell_path, null, null);

    // Wait for shell to start
    std.Thread.sleep(300 * std.time.ns_per_ms);

    // Resize should succeed without error
    try p.resize(120, 40);

    // Resize to small size should also work
    try p.resize(40, 10);

    // Resize back to standard
    try p.resize(80, 24);

    p.deinit();
}

test "PTY read produces output after spawn" {
    var p = try Pty.init(testing.allocator, .{ .cols = 80, .rows = 24 });

    const shell_path: [*:0]const u8 = if (comptime builtin.os.tag == .windows)
        "cmd.exe"
    else
        "/bin/sh";
    try p.spawn(shell_path, null, null);

    // Read some output (shell prompt, VT sequences)
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    const deadline = std.time.milliTimestamp() + 3000;

    while (std.time.milliTimestamp() < deadline and total == 0) {
        if (comptime builtin.os.tag == .windows) {
            // Windows: PeekNamedPipe before ReadFile to avoid blocking forever
            const PeekNamedPipe = @extern(*const fn (
                std.os.windows.HANDLE,
                ?[*]u8,
                std.os.windows.DWORD,
                ?*std.os.windows.DWORD,
                ?*std.os.windows.DWORD,
                ?*std.os.windows.DWORD,
            ) callconv(.c) std.os.windows.BOOL, .{ .name = "PeekNamedPipe", .library_name = "kernel32" });

            var avail: std.os.windows.DWORD = 0;
            const peek_ok = PeekNamedPipe(p.output_read, null, 0, null, &avail, null);
            if (peek_ok != 0 and avail > 0) {
                const n = p.read(buf[total..]) catch |err| {
                    if (err == error.ReadFailed) {
                        std.Thread.sleep(100 * std.time.ns_per_ms);
                        continue;
                    }
                    return err;
                };
                total += n;
            } else {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        } else {
            const n = p.read(buf[total..]) catch |err| {
                if (err == error.ReadFailed) {
                    std.Thread.sleep(100 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            total += n;
        }
        if (total == 0) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    try testing.expect(total > 0);

    p.deinit();
}

test "ConPTY specific: creation with different sizes" {
    if (comptime builtin.os.tag != .windows) {
        // This test only runs on Windows
        return;
    }

    // Test with various terminal sizes
    const sizes = [_][2]u16{
        .{ 80, 24 },
        .{ 120, 40 },
        .{ 40, 10 },
        .{ 200, 60 },
    };

    for (sizes) |size| {
        var p = try Pty.init(testing.allocator, .{ .cols = size[0], .rows = size[1] });
        try p.spawn("cmd.exe", null, null);
        const pid = p.getChildPid();
        try testing.expect(pid != null);
        p.deinit();
    }
}

test "Posix PTY specific: creation with different sizes" {
    if (comptime builtin.os.tag == .windows) {
        // This test only runs on Unix
        return;
    }

    const sizes = [_][2]u16{
        .{ 80, 24 },
        .{ 120, 40 },
        .{ 40, 10 },
        .{ 200, 60 },
    };

    for (sizes) |size| {
        var p = try Pty.init(testing.allocator, .{ .cols = size[0], .rows = size[1] });
        try p.spawn("/bin/sh", null, null);
        const pid = p.getChildPid();
        try testing.expect(pid != null);
        p.deinit();
    }
}
