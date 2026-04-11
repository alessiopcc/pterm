/// E2E tests: Agent detection pattern matching and idle detection (D-37).
///
/// Headless tests that feed known patterns to the AgentDetector and verify
/// state transitions. No GUI or PTY needed -- pure pattern matching.
const std = @import("std");
const testing = std.testing;
const agent_detector_mod = @import("agent_detector");
const AgentDetector = agent_detector_mod.AgentDetector;

// ============================================================================
// Pattern matching tests
// ============================================================================

test "detects claude code prompt pattern" {
    var detector = AgentDetector.init("conservative", &.{}, 3);
    defer detector.deinit();

    // Claude Code uses "? " prefix for prompts
    const lines = [_][]const u8{
        "Building project...",
        "Done in 3.2s",
        "? Do you want to proceed?",
    };

    const detected = detector.scanLines(&lines);
    try testing.expect(detected);
}

test "detects Y/n prompt pattern" {
    var detector = AgentDetector.init("conservative", &.{}, 3);
    defer detector.deinit();

    const lines = [_][]const u8{
        "Install dependencies?",
        "This will modify package.json",
        "Continue? (Y/n)",
    };

    const detected = detector.scanLines(&lines);
    try testing.expect(detected);
}

test "detects y/N prompt pattern" {
    var detector = AgentDetector.init("conservative", &.{}, 3);
    defer detector.deinit();

    const lines = [_][]const u8{
        "Delete all files?",
        "[y/N]",
    };

    const detected = detector.scanLines(&lines);
    try testing.expect(detected);
}

test "detects aider prompt" {
    var detector = AgentDetector.init("conservative", &.{}, 3);
    defer detector.deinit();

    const lines = [_][]const u8{
        "aider> ",
    };

    const detected = detector.scanLines(&lines);
    try testing.expect(detected);
}

test "detects generic prompt pattern" {
    var detector = AgentDetector.init("conservative", &.{}, 5);
    defer detector.deinit();

    const lines = [_][]const u8{
        "Processing files...",
        "Would you like me to continue with the changes?",
    };

    const detected = detector.scanLines(&lines);
    try testing.expect(detected);
}

// ============================================================================
// False positive prevention tests
// ============================================================================

test "no false positive on normal shell output" {
    var detector = AgentDetector.init("conservative", &.{}, 5);
    defer detector.deinit();

    // Normal ls output should not trigger
    const lines = [_][]const u8{
        "total 48",
        "drwxr-xr-x  2 user user  4096 Jan  1 00:00 .",
        "drwxr-xr-x  3 user user  4096 Jan  1 00:00 ..",
        "-rw-r--r--  1 user user  1234 Jan  1 00:00 file.txt",
        "-rw-r--r--  1 user user  5678 Jan  1 00:00 README.md",
    };

    const detected = detector.scanLines(&lines);
    try testing.expect(!detected);
}

test "no false positive on compiler output" {
    var detector = AgentDetector.init("conservative", &.{}, 5);
    defer detector.deinit();

    const lines = [_][]const u8{
        "Compiling src/main.zig...",
        "Linking...",
        "Build completed in 2.3s",
        "0 errors, 0 warnings",
    };

    const detected = detector.scanLines(&lines);
    try testing.expect(!detected);
}

// ============================================================================
// Broad preset tests
// ============================================================================

test "broad preset detects additional patterns" {
    var detector = AgentDetector.init("broad", &.{}, 5);
    defer detector.deinit();

    const lines = [_][]const u8{
        "Are you sure you want to continue?",
    };

    const detected = detector.scanLines(&lines);
    try testing.expect(detected);
}

test "broad preset detects press enter" {
    var detector = AgentDetector.init("broad", &.{}, 5);
    defer detector.deinit();

    const lines = [_][]const u8{
        "Press Enter to continue...",
    };

    const detected = detector.scanLines(&lines);
    try testing.expect(detected);
}

// ============================================================================
// Custom pattern tests
// ============================================================================

test "custom patterns are matched" {
    const custom = [_][]const u8{
        "my-custom-agent>",
    };
    var detector = AgentDetector.init("conservative", &custom, 3);
    defer detector.deinit();

    const lines = [_][]const u8{
        "my-custom-agent> waiting for input",
    };

    const detected = detector.scanLines(&lines);
    try testing.expect(detected);
}

test "scan line limit respected" {
    // Only scan last 2 lines -- pattern in line 1 of 4 should not match
    var detector = AgentDetector.init("conservative", &.{}, 2);
    defer detector.deinit();

    const lines = [_][]const u8{
        "? Do you want to proceed?", // This is beyond scan range
        "normal output line 2",
        "normal output line 3",
        "normal output line 4",
    };

    const detected = detector.scanLines(&lines);
    try testing.expect(!detected);
}

test "empty lines do not trigger detection" {
    var detector = AgentDetector.init("conservative", &.{}, 5);
    defer detector.deinit();

    const lines = [_][]const u8{
        "",
        "",
        "",
    };

    const detected = detector.scanLines(&lines);
    try testing.expect(!detected);
}

// ============================================================================
// Idle detection (conceptual test -- verifies timing infrastructure)
// ============================================================================

test "idle detection timing infrastructure" {
    // The AgentDetector doesn't directly implement idle detection --
    // it's handled by the monitoring loop. This test verifies that
    // the timing primitives needed for idle detection work correctly.
    const start = std.time.milliTimestamp();
    std.Thread.sleep(50 * std.time.ns_per_ms);
    const elapsed = std.time.milliTimestamp() - start;

    // Should have elapsed at least 40ms (some tolerance for scheduling)
    try testing.expect(elapsed >= 40);

    // This demonstrates the timing mechanism used by idle detection:
    // If no output for N seconds, and last line matches prompt pattern,
    // trigger idle alert.
}
