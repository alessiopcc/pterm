/// Build a Windows command line from separate arguments.
///
/// CreateProcessW takes one command line string, and the child splits it back
/// into arguments with the Microsoft C runtime rules. An argument with a space,
/// tab or quote (or an empty one) must be quoted, or the child sees it as
/// several arguments: `C:\Program Files\PowerShell\7\pwsh.exe` would arrive
/// as `C:\Program` and `Files\PowerShell\7\pwsh.exe`.
const std = @import("std");

pub const Error = error{ TooLong, InvalidUtf8 };

/// Append `arg` (UTF-8) to `out` at `pos` as UTF-16, quoted when needed.
/// Returns the new position. Always leaves room for a terminating NUL.
pub fn appendArg(out: []u16, pos: usize, arg: []const u8) Error!usize {
    // A UTF-8 string never needs more UTF-16 units than it has bytes.
    var wide_buf: [2048]u16 = undefined;
    if (arg.len > wide_buf.len) return error.TooLong;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, arg) catch return error.InvalidUtf8;
    const wide = wide_buf[0..n];

    var w = Writer{ .out = out, .pos = pos };
    const needs_quotes = wide.len == 0 or for (wide) |c| {
        if (c == ' ' or c == '\t' or c == '"') break true;
    } else false;
    if (!needs_quotes) {
        for (wide) |c| try w.put(c);
        return w.pos;
    }

    // Inside quotes, backslashes are literal unless they precede a quote:
    // then each one is doubled, and the quote itself is escaped.
    try w.put('"');
    var backslashes: usize = 0;
    for (wide) |c| {
        if (c == '\\') {
            backslashes += 1;
        } else if (c == '"') {
            try w.repeat('\\', backslashes * 2 + 1);
            try w.put('"');
            backslashes = 0;
        } else {
            try w.repeat('\\', backslashes);
            try w.put(c);
            backslashes = 0;
        }
    }
    // Trailing backslashes precede the closing quote, so double them.
    try w.repeat('\\', backslashes * 2);
    try w.put('"');
    return w.pos;
}

const Writer = struct {
    out: []u16,
    pos: usize,

    fn put(self: *Writer, c: u16) Error!void {
        if (self.pos + 1 >= self.out.len) return error.TooLong;
        self.out[self.pos] = c;
        self.pos += 1;
    }

    fn repeat(self: *Writer, c: u16, count: usize) Error!void {
        for (0..count) |_| try self.put(c);
    }
};

fn expectArg(arg: []const u8, expected: []const u8) !void {
    var out: [256]u16 = undefined;
    const n = try appendArg(&out, 0, arg);
    var utf8: [512]u8 = undefined;
    const len = try std.unicode.utf16LeToUtf8(&utf8, out[0..n]);
    try std.testing.expectEqualStrings(expected, utf8[0..len]);
}

test "appendArg leaves plain arguments alone" {
    try expectArg("-NoLogo", "-NoLogo");
    try expectArg("C:\\Windows\\cmd.exe", "C:\\Windows\\cmd.exe");
}

test "appendArg quotes spaces, tabs and empty arguments" {
    try expectArg("C:\\Program Files\\PowerShell\\7\\pwsh.exe", "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\"");
    try expectArg("a\tb", "\"a\tb\"");
    try expectArg("", "\"\"");
}

test "appendArg escapes quotes and the backslashes before them" {
    try expectArg("say \"hi\"", "\"say \\\"hi\\\"\"");
    try expectArg("a\\\"b", "\"a\\\\\\\"b\"");
    // Trailing backslash before the closing quote is doubled.
    try expectArg("C:\\My Dir\\", "\"C:\\My Dir\\\\\"");
}

test "appendArg refuses to overflow and keeps room for NUL" {
    var out: [4]u16 = undefined;
    try std.testing.expectError(error.TooLong, appendArg(&out, 0, "abcd"));
    try std.testing.expectEqual(@as(usize, 3), try appendArg(&out, 0, "abc"));
}
