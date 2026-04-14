/// URL detection via prefix scanning on u21 codepoint arrays.
///
/// Detects URLs with http://, https://, file:// scheme prefixes in visible
/// terminal cell content. No regex library needed -- simple prefix scan
/// with boundary detection.
const std = @import("std");

pub const UrlRange = struct {
    row: u32,
    col_start: u16,
    col_end: u16, // exclusive
};

/// Scheme prefixes as u21 codepoint arrays.
const scheme_http = toU21Comptime("http://");
const scheme_https = toU21Comptime("https://");
const scheme_file = toU21Comptime("file://");

/// Convert a comptime ASCII string to a u21 array.
fn toU21Comptime(comptime s: []const u8) [s.len]u21 {
    var result: [s.len]u21 = undefined;
    for (s, 0..) |c, i| {
        result[i] = @intCast(c);
    }
    return result;
}

/// Characters that terminate a URL.
fn isUrlTerminator(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '>', '"', '\'', '`', '<' => true,
        else => false,
    };
}

/// Detect all URLs in the given lines of u21 codepoints.
/// `start_row` is the row offset added to UrlRange.row for each line.
/// Caller owns the returned slice.
pub fn detectUrls(lines: []const []const u21, start_row: u32, allocator: std.mem.Allocator) ![]UrlRange {
    var results = std.ArrayListUnmanaged(UrlRange){};
    errdefer results.deinit(allocator);

    for (lines, 0..) |line, line_idx| {
        var col: u16 = 0;
        while (col < line.len) {
            const remaining = line[col..];
            const scheme_len = matchScheme(remaining);
            if (scheme_len > 0) {
                // Found a scheme prefix -- extend forward to find URL end.
                const url_end = findUrlEnd(line, col, @intCast(col + scheme_len));
                if (url_end > col + scheme_len) {
                    try results.append(allocator, UrlRange{
                        .row = start_row + @as(u32, @intCast(line_idx)),
                        .col_start = col,
                        .col_end = url_end,
                    });
                    col = url_end;
                    continue;
                }
            }
            col += 1;
        }
    }

    return results.toOwnedSlice(allocator);
}

/// Check if the line at the given position starts with a recognized scheme.
/// Returns the scheme length (e.g., 7 for "http://", 8 for "https://"), or 0.
fn matchScheme(remaining: []const u21) u16 {
    const schemes = [_][]const u21{
        &scheme_https, // Check https before http (longer prefix first)
        &scheme_http,
        &scheme_file,
    };
    for (schemes) |scheme| {
        if (remaining.len >= scheme.len) {
            var match = true;
            for (scheme, 0..) |sch_cp, si| {
                // Case-insensitive scheme matching
                const line_cp = remaining[si];
                const lower_line = if (line_cp >= 'A' and line_cp <= 'Z') line_cp + 32 else line_cp;
                const lower_sch = if (sch_cp >= 'A' and sch_cp <= 'Z') sch_cp + 32 else sch_cp;
                if (lower_line != lower_sch) {
                    match = false;
                    break;
                }
            }
            if (match) return @intCast(scheme.len);
        }
    }
    return 0;
}

/// Find the end column (exclusive) of a URL starting at `col_start`.
/// Handles unmatched closing parens, terminators, and whitespace.
fn findUrlEnd(line: []const u21, _: u16, after_scheme: u16) u16 {
    var open_parens: u32 = 0;
    var pos: u16 = after_scheme;

    while (pos < line.len) {
        const cp = line[pos];

        // Whitespace or explicit terminators always end the URL
        if (isUrlTerminator(cp)) break;

        // Track parentheses
        if (cp == '(') {
            open_parens += 1;
        } else if (cp == ')') {
            if (open_parens == 0) break; // Unmatched close paren ends URL
            open_parens -= 1;
        }

        pos += 1;
    }

    // Trim trailing punctuation that is often not part of the URL
    while (pos > after_scheme) {
        const last = line[pos - 1];
        if (last == '.' or last == ',' or last == ';' or last == ':' or last == '!') {
            pos -= 1;
        } else {
            break;
        }
    }

    return pos;
}

/// Convert u21 codepoints from a UrlRange to a UTF-8 string in the provided buffer.
/// Returns the valid UTF-8 slice.
pub fn extractUrlString(line: []const u21, range: UrlRange, buf: []u8) []const u8 {
    var written: usize = 0;
    const start = range.col_start;
    const end = @min(range.col_end, @as(u16, @intCast(line.len)));

    for (line[start..end]) |cp| {
        const len = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
        if (written + len > buf.len) break;
        const n = std.unicode.utf8Encode(cp, buf[written..]) catch continue;
        written += n;
    }

    return buf[0..written];
}

// =============================================================================
// Tests
// =============================================================================

/// Test helper: convert an ASCII string to a heap-allocated u21 slice.
fn toU21Slice(allocator: std.mem.Allocator, s: []const u8) ![]u21 {
    const result = try allocator.alloc(u21, s.len);
    for (s, 0..) |c, i| {
        result[i] = @intCast(c);
    }
    return result;
}

test "detectUrls finds https://example.com" {
    const allocator = std.testing.allocator;
    const line = try toU21Slice(allocator, "https://example.com");
    defer allocator.free(line);
    const lines: []const []const u21 = &.{line};

    const urls = try detectUrls(lines, 0, allocator);
    defer allocator.free(urls);

    try std.testing.expectEqual(@as(usize, 1), urls.len);
    try std.testing.expectEqual(@as(u16, 0), urls[0].col_start);
    try std.testing.expectEqual(@as(u16, 19), urls[0].col_end);
    try std.testing.expectEqual(@as(u32, 0), urls[0].row);
}

test "detectUrls finds http://foo.bar/baz at column 5" {
    const allocator = std.testing.allocator;
    const line = try toU21Slice(allocator, "text http://foo.bar/baz more text");
    defer allocator.free(line);
    const lines: []const []const u21 = &.{line};

    const urls = try detectUrls(lines, 0, allocator);
    defer allocator.free(urls);

    try std.testing.expectEqual(@as(usize, 1), urls.len);
    try std.testing.expectEqual(@as(u16, 5), urls[0].col_start);
    try std.testing.expectEqual(@as(u16, 23), urls[0].col_end);
}

test "detectUrls does NOT match bare example.com" {
    const allocator = std.testing.allocator;
    const line = try toU21Slice(allocator, "visit example.com today");
    defer allocator.free(line);
    const lines: []const []const u21 = &.{line};

    const urls = try detectUrls(lines, 0, allocator);
    defer allocator.free(urls);

    try std.testing.expectEqual(@as(usize, 0), urls.len);
}

test "detectUrls does NOT match ftp://files.host" {
    const allocator = std.testing.allocator;
    const line = try toU21Slice(allocator, "get ftp://files.host/data");
    defer allocator.free(line);
    const lines: []const []const u21 = &.{line};

    const urls = try detectUrls(lines, 0, allocator);
    defer allocator.free(urls);

    try std.testing.expectEqual(@as(usize, 0), urls.len);
}

test "detectUrls stops at whitespace" {
    const allocator = std.testing.allocator;
    const line = try toU21Slice(allocator, "https://example.com rest");
    defer allocator.free(line);
    const lines: []const []const u21 = &.{line};

    const urls = try detectUrls(lines, 0, allocator);
    defer allocator.free(urls);

    try std.testing.expectEqual(@as(usize, 1), urls.len);
    try std.testing.expectEqual(@as(u16, 19), urls[0].col_end);
}

test "detectUrls stops at unmatched closing paren" {
    const allocator = std.testing.allocator;
    const line = try toU21Slice(allocator, "https://example.com)");
    defer allocator.free(line);
    const lines: []const []const u21 = &.{line};

    const urls = try detectUrls(lines, 0, allocator);
    defer allocator.free(urls);

    try std.testing.expectEqual(@as(usize, 1), urls.len);
    try std.testing.expectEqual(@as(u16, 19), urls[0].col_end);
}

test "detectUrls stops at quote" {
    const allocator = std.testing.allocator;
    const line = try toU21Slice(allocator, "https://example.com\"");
    defer allocator.free(line);
    const lines: []const []const u21 = &.{line};

    const urls = try detectUrls(lines, 0, allocator);
    defer allocator.free(urls);

    try std.testing.expectEqual(@as(usize, 1), urls.len);
    try std.testing.expectEqual(@as(u16, 19), urls[0].col_end);
}

test "detectUrls stops at >" {
    const allocator = std.testing.allocator;
    const line = try toU21Slice(allocator, "https://example.com>");
    defer allocator.free(line);
    const lines: []const []const u21 = &.{line};

    const urls = try detectUrls(lines, 0, allocator);
    defer allocator.free(urls);

    try std.testing.expectEqual(@as(usize, 1), urls.len);
    try std.testing.expectEqual(@as(u16, 19), urls[0].col_end);
}

test "detectUrls finds multiple URLs in one line" {
    const allocator = std.testing.allocator;
    const line = try toU21Slice(allocator, "see https://a.com and http://b.org here");
    defer allocator.free(line);
    const lines: []const []const u21 = &.{line};

    const urls = try detectUrls(lines, 0, allocator);
    defer allocator.free(urls);

    try std.testing.expectEqual(@as(usize, 2), urls.len);
    try std.testing.expectEqual(@as(u16, 4), urls[0].col_start);
    try std.testing.expectEqual(@as(u16, 17), urls[0].col_end);
    try std.testing.expectEqual(@as(u16, 22), urls[1].col_start);
    try std.testing.expectEqual(@as(u16, 34), urls[1].col_end);
}

test "detectUrls handles file:///home/user/doc.txt" {
    const allocator = std.testing.allocator;
    const line = try toU21Slice(allocator, "file:///home/user/doc.txt");
    defer allocator.free(line);
    const lines: []const []const u21 = &.{line};

    const urls = try detectUrls(lines, 0, allocator);
    defer allocator.free(urls);

    try std.testing.expectEqual(@as(usize, 1), urls.len);
    try std.testing.expectEqual(@as(u16, 0), urls[0].col_start);
    try std.testing.expectEqual(@as(u16, 25), urls[0].col_end);
}

test "extractUrlString converts u21 to UTF-8" {
    const allocator = std.testing.allocator;
    const line = try toU21Slice(allocator, "https://example.com");
    defer allocator.free(line);

    var buf: [2048]u8 = undefined;
    const range = UrlRange{ .row = 0, .col_start = 0, .col_end = 19 };
    const result = extractUrlString(line, range, &buf);
    try std.testing.expectEqualStrings("https://example.com", result);
}
