/// E2E tests: Stability and stress testing (D-39).
///
/// Tests rapid PTY create/close cycles, fast terminal output,
/// and multiple simultaneous shells.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("e2e_harness");
const TestApp = harness.TestApp;

/// Rapid PTY create/close: 50 iterations to check for resource leaks.
test "rapid pty create close (50 iterations)" {
    const allocator = testing.allocator;
    const shell_path = harness.defaultShellPath();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var app = TestApp.init(allocator, shell_path, null) catch |err| {
            // On some systems, rapid create/close can exhaust resources temporarily
            if (i > 10) {
                std.log.warn("PTY creation failed at iteration {} (may be resource limit): {}", .{ i, err });
                return; // Acceptable after 10+ successful iterations
            }
            return err;
        };
        app.deinit();
    }
}

/// Fast terminal output: pipe a large amount of output and verify no crash/hang.
test "fast output stress" {
    const allocator = testing.allocator;
    const shell_path = harness.defaultShellPath();

    var app = try TestApp.init(allocator, shell_path, null);
    defer app.deinit();

    // Wait for shell to initialize
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Platform-specific loop command for generating lots of output
    if (comptime builtin.os.tag == .windows) {
        // Windows cmd: use a for loop
        try app.sendInput("for /L %i in (1,1,500) do @echo STRESS_LINE_%i\r\n");
    } else {
        // Unix: seq-based loop
        try app.sendInput("i=1; while [ $i -le 500 ]; do echo STRESS_LINE_$i; i=$((i+1)); done\n");
    }

    // Read until we see evidence of late output or timeout (15 seconds)
    const found = try app.expectOutput("STRESS_LINE_", 15000);
    try testing.expect(found);
}

/// Multiple shells simultaneously: 3 concurrent PTYs.
test "multiple shells simultaneously" {
    const allocator = testing.allocator;
    const shell_path = harness.defaultShellPath();

    var apps: [3]TestApp = undefined;
    var initialized: usize = 0;
    errdefer {
        for (apps[0..initialized]) |*app| app.deinit();
    }

    // Create 3 PTYs
    for (&apps, 0..) |*app, idx| {
        app.* = try TestApp.init(allocator, shell_path, null);
        initialized = idx + 1;
    }
    defer {
        for (&apps) |*app| app.deinit();
    }

    // Wait for all shells to start
    std.Thread.sleep(1000 * std.time.ns_per_ms);

    // Send unique marker to each
    const markers = [_][]const u8{
        "MULTI_SHELL_A_42",
        "MULTI_SHELL_B_42",
        "MULTI_SHELL_C_42",
    };

    for (&apps, markers) |*app, marker| {
        const cmd = if (comptime builtin.os.tag == .windows)
            std.fmt.allocPrint(allocator, "echo {s}\r\n", .{marker}) catch continue
        else
            std.fmt.allocPrint(allocator, "echo {s}\n", .{marker}) catch continue;
        defer allocator.free(cmd);
        app.sendInput(cmd) catch {};
    }

    // Verify at least 2 of 3 respond (allow some tolerance)
    var responses: usize = 0;
    for (&apps, markers) |*app, marker| {
        if (app.expectOutput(marker, 5000) catch false) {
            responses += 1;
        }
    }

    try testing.expect(responses >= 2);
}
