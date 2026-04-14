/// Smartcase string matching and scrollback+screen scanning (CORE-08).
///
/// Provides:
///   - isSmartcaseSensitive: Vim-style smartcase detection
///   - matchLine: find all occurrences of query in a line of codepoints
///   - findMatches: scan scrollback buffer + screen lines for all matches
///
/// Plain text search only. ASCII case folding sufficient for v1 (A2).
/// Linear scan is O(n) and bounded by scrollback capacity (T-06-01).
const std = @import("std");
const SearchState = @import("SearchState.zig").SearchState;

/// Returns true if the query contains any uppercase ASCII letter.
/// Empty query returns false (case-insensitive).
pub fn isSmartcaseSensitive(query: []const u8) bool {
    for (query) |c| {
        if (c >= 'A' and c <= 'Z') return true;
    }
    return false;
}

/// Convert an ASCII byte to lowercase (for case-insensitive comparison).
fn toLowerAscii(c: u21) u21 {
    if (c >= 'A' and c <= 'Z') return c + ('a' - 'A');
    return c;
}

/// Find all occurrences of query in a line of u21 codepoints.
/// Returns allocated slice of Match structs (caller owns memory).
pub fn matchLine(
    line: []const u21,
    query: []const u8,
    case_sensitive: bool,
    line_index: u32,
    in_scrollback: bool,
    allocator: std.mem.Allocator,
) ![]SearchState.Match {
    var results: std.ArrayListUnmanaged(SearchState.Match) = .{};
    errdefer results.deinit(allocator);

    if (query.len == 0 or line.len == 0 or query.len > line.len) {
        return results.toOwnedSlice(allocator);
    }

    // Convert query bytes to u21 for comparison
    var query_cps: [256]u21 = undefined;
    for (query, 0..) |c, i| {
        query_cps[i] = @intCast(c);
    }
    const query_u21 = query_cps[0..query.len];

    // Sliding window search
    const max_start = line.len - query.len;
    var pos: usize = 0;
    while (pos <= max_start) {
        var matched = true;
        for (0..query.len) |j| {
            const line_cp = line[pos + j];
            const query_cp = query_u21[j];
            const eq = if (case_sensitive)
                line_cp == query_cp
            else
                toLowerAscii(line_cp) == toLowerAscii(query_cp);
            if (!eq) {
                matched = false;
                break;
            }
        }
        if (matched) {
            try results.append(allocator, .{
                .line_index = line_index,
                .col_start = @intCast(pos),
                .col_end = @intCast(pos + query.len),
                .in_scrollback = in_scrollback,
            });
            pos += query.len; // Skip past match to avoid overlapping results
        } else {
            pos += 1;
        }
    }

    return results.toOwnedSlice(allocator);
}

/// Scan scrollback buffer + screen lines for all matches.
/// Scrollback lines accessed via getLine(0..lineCount), then screen lines.
/// Returns allocated slice of all Match structs (caller owns memory).
pub fn findMatches(
    scrollback_lines: []const []const u21,
    screen_lines: []const []const u21,
    query: []const u8,
    allocator: std.mem.Allocator,
) ![]SearchState.Match {
    if (query.len < 2) return allocator.alloc(SearchState.Match, 0);

    const case_sensitive = isSmartcaseSensitive(query);
    var all_matches: std.ArrayListUnmanaged(SearchState.Match) = .{};
    errdefer all_matches.deinit(allocator);

    // Scan scrollback lines
    for (scrollback_lines, 0..) |line, i| {
        const line_matches = try matchLine(line, query, case_sensitive, @intCast(i), true, allocator);
        defer allocator.free(line_matches);
        try all_matches.appendSlice(allocator, line_matches);
    }

    // Scan screen lines
    const scrollback_count: u32 = @intCast(scrollback_lines.len);
    for (screen_lines, 0..) |line, i| {
        const line_idx = scrollback_count + @as(u32, @intCast(i));
        const line_matches = try matchLine(line, query, case_sensitive, line_idx, false, allocator);
        defer allocator.free(line_matches);
        try all_matches.appendSlice(allocator, line_matches);
    }

    return all_matches.toOwnedSlice(allocator);
}

// -------------------------------------------------------
// Tests
// -------------------------------------------------------

test "smartcase: all lowercase returns false (case-insensitive)" {
    try std.testing.expect(!isSmartcaseSensitive("hello"));
}

test "smartcase: uppercase present returns true (case-sensitive)" {
    try std.testing.expect(isSmartcaseSensitive("Hello"));
}

test "smartcase: empty query returns false" {
    try std.testing.expect(!isSmartcaseSensitive(""));
}

test "smartcase: numbers and symbols return false" {
    try std.testing.expect(!isSmartcaseSensitive("123!@#"));
}

test "matchLine: finds 'test' in 'this is a test line' at correct position" {
    const allocator = std.testing.allocator;
    const line = [_]u21{ 't', 'h', 'i', 's', ' ', 'i', 's', ' ', 'a', ' ', 't', 'e', 's', 't', ' ', 'l', 'i', 'n', 'e' };
    const matches = try matchLine(&line, "test", false, 0, false, allocator);
    defer allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(@as(u16, 10), matches[0].col_start);
    try std.testing.expectEqual(@as(u16, 14), matches[0].col_end);
}

test "matchLine: case-insensitive finds 'test' in 'TEST'" {
    const allocator = std.testing.allocator;
    const line = [_]u21{ 'T', 'h', 'i', 's', ' ', 'I', 's', ' ', 'A', ' ', 'T', 'E', 'S', 'T', ' ', 'L', 'i', 'n', 'e' };
    const matches = try matchLine(&line, "test", false, 0, false, allocator);
    defer allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(@as(u16, 10), matches[0].col_start);
}

test "matchLine: case-sensitive does NOT find 'test' in 'TEST'" {
    const allocator = std.testing.allocator;
    const line = [_]u21{ 'T', 'h', 'i', 's', ' ', 'I', 's', ' ', 'A', ' ', 'T', 'E', 'S', 'T', ' ', 'L', 'i', 'n', 'e' };
    const matches = try matchLine(&line, "test", true, 0, false, allocator);
    defer allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "matchLine: finds multiple occurrences in one line" {
    const allocator = std.testing.allocator;
    const line = [_]u21{ 'a', 'b', 'a', 'b', 'a', 'b' };
    const matches = try matchLine(&line, "ab", false, 0, false, allocator);
    defer allocator.free(matches);

    // "ababab" contains "ab" at positions 0, 2, 4
    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqual(@as(u16, 0), matches[0].col_start);
    try std.testing.expectEqual(@as(u16, 2), matches[1].col_start);
    try std.testing.expectEqual(@as(u16, 4), matches[2].col_start);
}

test "matchLine: returns empty for no match" {
    const allocator = std.testing.allocator;
    const line = [_]u21{ 'h', 'e', 'l', 'l', 'o' };
    const matches = try matchLine(&line, "xyz", false, 0, false, allocator);
    defer allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "matchLine: empty query returns empty" {
    const allocator = std.testing.allocator;
    const line = [_]u21{ 'h', 'e', 'l', 'l', 'o' };
    const matches = try matchLine(&line, "", false, 0, false, allocator);
    defer allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "findMatches: scans scrollback and screen lines" {
    const allocator = std.testing.allocator;

    const scrollback_line1 = [_]u21{ 'f', 'o', 'o', ' ', 'b', 'a', 'r' };
    const scrollback_line2 = [_]u21{ 'b', 'a', 'z', ' ', 'f', 'o', 'o' };
    const screen_line1 = [_]u21{ 'f', 'o', 'o', ' ', 'h', 'e', 'r', 'e' };

    const scrollback = [_][]const u21{ &scrollback_line1, &scrollback_line2 };
    const screen = [_][]const u21{&screen_line1};

    const matches = try findMatches(&scrollback, &screen, "foo", allocator);
    defer allocator.free(matches);

    // 3 matches: scrollback line 0, scrollback line 1, screen line 0
    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expect(matches[0].in_scrollback);
    try std.testing.expect(matches[1].in_scrollback);
    try std.testing.expect(!matches[2].in_scrollback);
}

test "findMatches: smartcase uppercase forces case-sensitive" {
    const allocator = std.testing.allocator;

    const line1 = [_]u21{ 'F', 'o', 'o' };
    const line2 = [_]u21{ 'f', 'o', 'o' };

    const scrollback = [_][]const u21{ &line1, &line2 };
    const screen = [_][]const u21{};

    // "Foo" has uppercase => case-sensitive, only matches "Foo" not "foo"
    const matches = try findMatches(&scrollback, &screen, "Foo", allocator);
    defer allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(@as(u32, 0), matches[0].line_index);
}
