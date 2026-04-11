/// Pattern matching engine for agent detection.
///
/// Scans the last N lines of terminal output for patterns that indicate
/// an AI coding agent is waiting for user input.
///
/// Two matching strategies:
///   1. Preset patterns (conservative/broad): literal byte substring matching via std.mem.indexOf
///   2. Custom patterns: literal byte substring matching (same as presets for v1)
///
/// Note: Custom patterns use literal string matching in v1. Regex support via mvzr
/// can be added in a future version when the dependency is available for Zig 0.15.2.
/// The public API is designed so this upgrade is transparent to callers.
const std = @import("std");
const presets = @import("presets");

pub const AgentDetector = struct {
    /// Preset pattern array (references presets.conservative_patterns or presets.broad_patterns).
    preset_patterns: []const []const u8,
    /// Custom user-provided patterns (literal string match in v1).
    custom_patterns: []const []const u8,
    /// Maximum number of lines from the end to scan.
    scan_lines: u32,

    /// Create a new AgentDetector.
    ///
    /// preset_name: "conservative" or "broad" (falls back to "conservative" on unknown).
    /// custom_pattern_slice: user-provided patterns from config. Invalid patterns are
    ///   logged and skipped (never panic on bad user config per T-03).
    /// scan_line_count: maximum number of lines from the end to check.
    pub fn init(
        preset_name: []const u8,
        custom_pattern_slice: []const []const u8,
        scan_line_count: u32,
    ) AgentDetector {
        const preset_ptrs: []const []const u8 = if (std.mem.eql(u8, preset_name, "broad"))
            &presets.broad_patterns
        else blk: {
            if (!std.mem.eql(u8, preset_name, "conservative")) {
                std.log.warn("Unknown agent preset '{s}', falling back to 'conservative'", .{preset_name});
            }
            break :blk &presets.conservative_patterns;
        };

        // Validate custom patterns -- in v1 all strings are valid for literal matching,
        // but log a warning for empty patterns which would match everything.
        for (custom_pattern_slice) |pattern| {
            if (pattern.len == 0) {
                std.log.warn("Empty custom agent pattern skipped (would match all lines)", .{});
            }
        }

        return .{
            .preset_patterns = preset_ptrs,
            .custom_patterns = custom_pattern_slice,
            .scan_lines = scan_line_count,
        };
    }

    /// Scan terminal output lines for matching patterns.
    ///
    /// Checks at most `scan_lines` lines from the end of the slice.
    /// Returns true on first match (short-circuits).
    pub fn scanLines(self: *const AgentDetector, lines: []const []const u8) bool {
        if (lines.len == 0) return false;

        // Determine scan range: last N lines
        const start = if (lines.len > self.scan_lines)
            lines.len - self.scan_lines
        else
            0;

        for (lines[start..]) |line| {
            // Check preset patterns (literal substring match)
            for (self.preset_patterns) |pattern| {
                if (std.mem.indexOf(u8, line, pattern) != null) {
                    return true;
                }
            }
            // Check custom patterns (literal substring match in v1)
            for (self.custom_patterns) |pattern| {
                if (pattern.len == 0) continue; // Skip empty patterns
                if (std.mem.indexOf(u8, line, pattern) != null) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Cleanup. No-op in v1 (no heap allocations for literal matching).
    pub fn deinit(self: *AgentDetector) void {
        _ = self;
    }
};

// ── Tests ────────────────────────────────────────────────

test "init with conservative preset" {
    const detector = AgentDetector.init("conservative", &.{}, 3);
    try std.testing.expectEqual(@as(usize, presets.conservative_patterns.len), detector.preset_patterns.len);
    try std.testing.expectEqual(@as(u32, 3), detector.scan_lines);
}

test "init with broad preset" {
    const detector = AgentDetector.init("broad", &.{}, 5);
    try std.testing.expectEqual(@as(usize, presets.broad_patterns.len), detector.preset_patterns.len);
}

test "init with unknown preset falls back to conservative" {
    const detector = AgentDetector.init("unknown_preset", &.{}, 3);
    try std.testing.expectEqual(@as(usize, presets.conservative_patterns.len), detector.preset_patterns.len);
}

test "scanLines returns false on empty lines" {
    const detector = AgentDetector.init("conservative", &.{}, 3);
    const lines: []const []const u8 = &.{};
    try std.testing.expect(!detector.scanLines(lines));
}

test "scanLines returns false when no match" {
    const detector = AgentDetector.init("conservative", &.{}, 3);
    const lines = [_][]const u8{
        "compiling main.zig...",
        "Build successful",
        "Running tests",
    };
    try std.testing.expect(!detector.scanLines(&lines));
}

test "scanLines matches conservative pattern" {
    const detector = AgentDetector.init("conservative", &.{}, 3);
    const lines = [_][]const u8{
        "Some output here",
        "Do you want to proceed? (Y/n)",
        "",
    };
    try std.testing.expect(detector.scanLines(&lines));
}

test "scanLines matches pattern on last line" {
    const detector = AgentDetector.init("conservative", &.{}, 3);
    const lines = [_][]const u8{
        "Line 1",
        "Line 2",
        "aider> ",
    };
    try std.testing.expect(detector.scanLines(&lines));
}

test "scanLines respects scan_lines limit" {
    // Pattern is on line 1, but scan_lines=2 means only last 2 lines are checked
    const detector = AgentDetector.init("conservative", &.{}, 2);
    const lines = [_][]const u8{
        "Do you want to proceed?",
        "Normal output line",
        "Another normal line",
    };
    try std.testing.expect(!detector.scanLines(&lines));
}

test "scanLines matches broad pattern" {
    const detector = AgentDetector.init("broad", &.{}, 3);
    const lines = [_][]const u8{
        "Processing...",
        "Press Enter to continue",
        "",
    };
    try std.testing.expect(detector.scanLines(&lines));
}

test "scanLines matches custom pattern" {
    const custom = [_][]const u8{"my-custom-prompt>"};
    const detector = AgentDetector.init("conservative", &custom, 3);
    const lines = [_][]const u8{
        "Some output",
        "my-custom-prompt> ",
        "",
    };
    try std.testing.expect(detector.scanLines(&lines));
}

test "scanLines skips empty custom pattern" {
    const custom = [_][]const u8{""};
    const detector = AgentDetector.init("conservative", &custom, 3);
    const lines = [_][]const u8{
        "Normal line with no agent prompt",
    };
    // Empty pattern is skipped, and no preset pattern matches
    try std.testing.expect(!detector.scanLines(&lines));
}

test "deinit is safe" {
    var detector = AgentDetector.init("conservative", &.{}, 3);
    detector.deinit();
}
