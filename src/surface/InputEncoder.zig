/// Encode GLFW key events to VT escape sequences (UI-SPEC input contract).
///
/// Handles:
///   - Arrow keys, Home, End, Insert, Delete, Page Up/Down -> CSI sequences
///   - F1-F12 -> xterm-compatible escape sequences
///   - Ctrl+A through Ctrl+Z -> control codes 0x01-0x1A
///   - Tab, Escape, Backspace, Enter -> single-byte control codes
///   - Ctrl+C (no selection) -> 0x03 ETX (NOT intercepted for clipboard)
///   - Ctrl+V -> returns clipboard flag (caller reads GLFW clipboard)
///   - Ctrl+=/Ctrl+-/Ctrl+0 -> returns null (font resize, handled by Surface)
///   - Unicode codepoints -> UTF-8 encoding
const std = @import("std");
const glfw = @import("zglfw");

pub const Key = glfw.Key;
pub const Mods = glfw.Mods;

/// Result of key encoding.
pub const EncodeResult = union(enum) {
    /// VT bytes to write to the PTY.
    bytes: []const u8,
    /// Caller should paste clipboard contents to PTY.
    paste_clipboard,
    /// Key handled internally (font resize) -- do not send to PTY.
    handled_internally,
    /// Key not mapped / should be ignored.
    none,
};

/// Encode a GLFW key event into VT escape sequence bytes.
/// `buf` must be at least 16 bytes. Returns the result.
pub fn encodeKey(key: Key, mods: Mods, buf: []u8) EncodeResult {
    const ctrl = mods.control;
    const shift = mods.shift;
    _ = shift;

    // Ctrl+= (font zoom in), Ctrl+- (font zoom out), Ctrl+0 (font reset)
    if (ctrl) {
        switch (key) {
            .equal => return .handled_internally,
            .minus => return .handled_internally,
            .zero => return .handled_internally,
            .v => return .paste_clipboard,
            else => {},
        }
    }

    // Ctrl+letter -> control code (0x01 - 0x1A)
    if (ctrl) {
        const key_int = @intFromEnum(key);
        // GLFW keys A-Z are sequential (ASCII-based)
        const a_int = @intFromEnum(Key.a);
        const z_int = @intFromEnum(Key.z);
        if (key_int >= a_int and key_int <= z_int) {
            buf[0] = @intCast(key_int - a_int + 1);
            return .{ .bytes = buf[0..1] };
        }
    }

    // Special keys
    switch (key) {
        .escape => {
            buf[0] = 0x1B;
            return .{ .bytes = buf[0..1] };
        },
        .enter => {
            buf[0] = 0x0D;
            return .{ .bytes = buf[0..1] };
        },
        .tab => {
            buf[0] = 0x09;
            return .{ .bytes = buf[0..1] };
        },
        .backspace => {
            buf[0] = 0x7F;
            return .{ .bytes = buf[0..1] };
        },

        // Arrow keys -> ESC[A/B/C/D
        .up => return csiSequence(buf, 'A'),
        .down => return csiSequence(buf, 'B'),
        .right => return csiSequence(buf, 'C'),
        .left => return csiSequence(buf, 'D'),

        // Navigation keys
        .home => return csiSequence(buf, 'H'),
        .end => return csiSequence(buf, 'F'),
        .insert => return csiBracketSequence(buf, '2'),
        .delete => return csiBracketSequence(buf, '3'),
        .page_up => return csiBracketSequence(buf, '5'),
        .page_down => return csiBracketSequence(buf, '6'),

        // Function keys (xterm-compatible)
        .F1 => return ssSequence(buf, 'P'),
        .F2 => return ssSequence(buf, 'Q'),
        .F3 => return ssSequence(buf, 'R'),
        .F4 => return ssSequence(buf, 'S'),
        .F5 => return csiBracketNum(buf, "15"),
        .F6 => return csiBracketNum(buf, "17"),
        .F7 => return csiBracketNum(buf, "18"),
        .F8 => return csiBracketNum(buf, "19"),
        .F9 => return csiBracketNum(buf, "20"),
        .F10 => return csiBracketNum(buf, "21"),
        .F11 => return csiBracketNum(buf, "23"),
        .F12 => return csiBracketNum(buf, "24"),

        else => return .none,
    }
}

/// Encode a Unicode codepoint to UTF-8 bytes.
pub fn encodeChar(cp: u21, buf: []u8) []const u8 {
    if (buf.len < 4) return buf[0..0];
    const len = std.unicode.utf8Encode(cp, buf[0..4]) catch return buf[0..0];
    return buf[0..len];
}

// -- Internal helpers --

fn csiSequence(buf: []u8, final_byte: u8) EncodeResult {
    buf[0] = 0x1B;
    buf[1] = '[';
    buf[2] = final_byte;
    return .{ .bytes = buf[0..3] };
}

fn csiBracketSequence(buf: []u8, num: u8) EncodeResult {
    buf[0] = 0x1B;
    buf[1] = '[';
    buf[2] = num;
    buf[3] = '~';
    return .{ .bytes = buf[0..4] };
}

fn csiBracketNum(buf: []u8, num: []const u8) EncodeResult {
    buf[0] = 0x1B;
    buf[1] = '[';
    @memcpy(buf[2 .. 2 + num.len], num);
    buf[2 + num.len] = '~';
    return .{ .bytes = buf[0 .. 3 + num.len] };
}

fn ssSequence(buf: []u8, ch: u8) EncodeResult {
    buf[0] = 0x1B;
    buf[1] = 'O';
    buf[2] = ch;
    return .{ .bytes = buf[0..3] };
}

// -------------------------------------------------------
// Tests
// -------------------------------------------------------

test "arrow keys produce CSI sequences" {
    var buf: [16]u8 = undefined;
    const no_mods = Mods{};

    const up = encodeKey(.up, no_mods, &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[A", up.bytes);

    const down = encodeKey(.down, no_mods, &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[B", down.bytes);

    const right = encodeKey(.right, no_mods, &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[C", right.bytes);

    const left = encodeKey(.left, no_mods, &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[D", left.bytes);
}

test "Ctrl+C sends ETX (0x03)" {
    var buf: [16]u8 = undefined;
    const ctrl = Mods{ .control = true };

    const result = encodeKey(.c, ctrl, &buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x03}, result.bytes);
}

test "Ctrl+V returns paste_clipboard" {
    var buf: [16]u8 = undefined;
    const ctrl = Mods{ .control = true };

    const result = encodeKey(.v, ctrl, &buf);
    try std.testing.expectEqual(EncodeResult.paste_clipboard, result);
}

test "Ctrl+= returns handled_internally" {
    var buf: [16]u8 = undefined;
    const ctrl = Mods{ .control = true };

    const result = encodeKey(.equal, ctrl, &buf);
    try std.testing.expectEqual(EncodeResult.handled_internally, result);
}

test "Enter sends CR" {
    var buf: [16]u8 = undefined;
    const result = encodeKey(.enter, Mods{}, &buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x0D}, result.bytes);
}

test "Backspace sends DEL" {
    var buf: [16]u8 = undefined;
    const result = encodeKey(.backspace, Mods{}, &buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x7F}, result.bytes);
}

test "encodeChar ASCII 'A'" {
    var buf: [4]u8 = undefined;
    const result = encodeChar('A', &buf);
    try std.testing.expectEqualSlices(u8, "A", result);
}

test "encodeChar multibyte UTF-8" {
    var buf: [4]u8 = undefined;
    // U+00E9 (e with acute) should be 2 bytes: 0xC3 0xA9
    const result = encodeChar(0x00E9, &buf);
    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "F1 produces SS3 P" {
    var buf: [16]u8 = undefined;
    const result = encodeKey(.F1, Mods{}, &buf);
    try std.testing.expectEqualSlices(u8, "\x1bOP", result.bytes);
}

test "Delete produces CSI 3 ~" {
    var buf: [16]u8 = undefined;
    const result = encodeKey(.delete, Mods{}, &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[3~", result.bytes);
}
