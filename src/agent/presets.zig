/// Built-in agent detection pattern presets.
///
/// Two presets are provided:
///   - "conservative": Matches only well-known AI tool prompts (low false-positive rate)
///   - "broad": Superset of conservative, includes common shell confirmation prompts
///
/// All patterns are matched as literal byte substrings via std.mem.indexOf.
/// Custom user patterns (regex) are handled separately by AgentDetector.
/// Conservative preset: major AI coding tools only.
/// Targets Claude Code, Copilot CLI, Aider, Codex, and common inquirer.js prompts.
pub const conservative_patterns = [_][]const u8{
    "Do you want to proceed?",
    "Would you like me to",
    "? ",
    "(Y/n)",
    "(y/N)",
    "[Y/n]",
    "[y/N]",
    "aider> ",
    "? Run this command",
    "? Select a command",
};

/// Broad preset: conservative patterns plus common shell/CLI confirmation prompts.
/// Higher detection rate but may trigger on non-agent interactive prompts.
pub const broad_patterns = conservative_patterns ++ [_][]const u8{
    "Press Enter",
    "press enter",
    "Press any key",
    "press any key",
    "Continue? ",
    "continue? ",
    "(yes/no)",
    "[yes/no]",
    "Are you sure",
    "Proceed?",
};

// ── Tests ────────────────────────────────────────────────

const std = @import("std");

test "conservative_patterns contains expected entries" {
    var found_proceed = false;
    var found_inquirer = false;
    var found_aider = false;
    var found_yn = false;
    for (&conservative_patterns) |p| {
        if (std.mem.eql(u8, p, "Do you want to proceed?")) found_proceed = true;
        if (std.mem.eql(u8, p, "? ")) found_inquirer = true;
        if (std.mem.eql(u8, p, "aider> ")) found_aider = true;
        if (std.mem.eql(u8, p, "(Y/n)")) found_yn = true;
    }
    try std.testing.expect(found_proceed);
    try std.testing.expect(found_inquirer);
    try std.testing.expect(found_aider);
    try std.testing.expect(found_yn);
}

test "broad_patterns is superset of conservative_patterns" {
    // broad must contain all conservative patterns
    for (&conservative_patterns) |cp| {
        var found = false;
        for (&broad_patterns) |bp| {
            if (std.mem.eql(u8, cp, bp)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
    // broad must have more patterns than conservative
    try std.testing.expect(broad_patterns.len > conservative_patterns.len);
}

test "broad_patterns contains additional entries" {
    var found_press_enter = false;
    var found_are_you_sure = false;
    var found_proceed = false;
    for (&broad_patterns) |p| {
        if (std.mem.eql(u8, p, "Press Enter")) found_press_enter = true;
        if (std.mem.eql(u8, p, "Are you sure")) found_are_you_sure = true;
        if (std.mem.eql(u8, p, "Proceed?")) found_proceed = true;
    }
    try std.testing.expect(found_press_enter);
    try std.testing.expect(found_are_you_sure);
    try std.testing.expect(found_proceed);
}
