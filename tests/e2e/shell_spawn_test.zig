/// E2E tests: Shell spawn and I/O for all platform shells.
///
/// For each available shell:
/// - Spawn via TestApp
/// - Send echo command with marker
/// - Verify marker appears in output
/// - ShellCategory determines failure behavior:
///   * blocking: test failure = overall failure
///   * warning_only: log warning, don't fail
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("e2e_harness");
const TestApp = harness.TestApp;
const ShellCategory = harness.ShellCategory;

const MARKER = "PTERM_E2E_MARKER_7f3a";

// Test all available shells on this platform.
test "shell spawn and echo marker for all available shells" {
    const allocator = testing.allocator;
    const shells = try harness.availableShells(allocator);
    defer {
        for (shells) |shell| {
            // Free heap-allocated paths from tryAddShellFromPath
            // (static paths from tryAddShell are string literals and won't be freed).
            allocator.free(shell.path);
        }
        allocator.free(shells);
    }

    if (shells.len == 0) {
        std.log.warn("No shells detected on this system -- skipping shell spawn tests", .{});
        return;
    }

    var blocking_failures: usize = 0;

    for (shells) |shell| {
        const result = testShellEcho(allocator, shell);
        if (result) |_| {
            std.log.info("PASS: {s} shell spawn + echo", .{shell.name});
        } else |err| {
            switch (shell.category) {
                .blocking => {
                    std.log.err("FAIL (blocking): {s} shell spawn failed: {}", .{ shell.name, err });
                    blocking_failures += 1;
                },
                .warning_only => {
                    std.log.warn("WARN (warning_only): {s} shell not available or failed: {}", .{ shell.name, err });
                },
            }
        }
    }

    try testing.expectEqual(@as(usize, 0), blocking_failures);
}

/// Test spawning a single shell and echoing a marker.
fn testShellEcho(allocator: std.mem.Allocator, shell: harness.ShellInfo) !void {
    var app = try TestApp.init(allocator, shell.path, null);
    defer app.deinit();

    // Wait briefly for shell to initialize
    std.Thread.sleep(200 * std.time.ns_per_ms);

    // Send echo command appropriate for the shell
    const echo_cmd = if (comptime builtin.os.tag == .windows)
        if (std.mem.eql(u8, shell.name, "powershell"))
            "Write-Output '" ++ MARKER ++ "'\r\n"
        else
            "echo " ++ MARKER ++ "\r\n"
    else
        "echo " ++ MARKER ++ "\n";

    try app.sendInput(echo_cmd);

    // Verify marker appears in output within 10 seconds
    const found = try app.expectOutput(MARKER, 3000);
    if (!found) return error.MarkerNotFound;
}

// Test default shell specifically.
test "default shell spawn and basic I/O" {
    const allocator = testing.allocator;
    const default_path = harness.defaultShellPath();

    var app = try TestApp.init(allocator, default_path, null);
    defer app.deinit();

    // Shell should produce some initial output (prompt, VT sequences)
    var buf: [4096]u8 = undefined;
    const n = try app.readOutputTimeout(&buf, 3000);
    try testing.expect(n > 0);
}
