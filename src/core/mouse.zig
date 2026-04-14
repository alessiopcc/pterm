/// SGR mouse protocol event handling (CORE-10).
///
/// Parses and encodes SGR extended mouse reports (mode 1006).
/// Format: ESC [ < Cb ; Cx ; Cy M (press) or ESC [ < Cb ; Cx ; Cy m (release)
///
/// Cb encodes button + modifiers:
///   bits 0-1: button (0=left, 1=middle, 2=right, 3=release)
///   bit 2: shift
///   bit 3: alt/meta
///   bit 4: ctrl
///   bit 5: motion (drag)
///   bit 6: scroll (64=up, 65=down)
const std = @import("std");

pub const MouseButton = enum {
    left,
    middle,
    right,
    scroll_up,
    scroll_down,
    none,
};

pub const MouseAction = enum {
    press,
    release,
    motion,
};

pub const Modifiers = packed struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

pub const MouseEvent = struct {
    button: MouseButton,
    action: MouseAction,
    row: u16,
    col: u16,
    modifiers: Modifiers,
};

pub const MouseError = error{
    InvalidFormat,
    InvalidNumber,
    MissingTerminator,
};

/// Parse SGR extended mouse report parameters.
/// Input: the parameter bytes AFTER "ESC [ <" up to and including the terminator (M or m).
/// For example: "0;10;5M" for left button press at col 10, row 5.
pub fn parseSgrMouse(params: []const u8) MouseError!MouseEvent {
    if (params.len == 0) return MouseError.InvalidFormat;

    // Find the terminator (M = press, m = release)
    const last = params[params.len - 1];
    const is_release = last == 'm';
    const is_press = last == 'M';
    if (!is_release and !is_press) return MouseError.MissingTerminator;

    // Parse the three semicolon-separated numbers: Cb;Cx;Cy
    const param_str = params[0 .. params.len - 1];
    var parts: [3][]const u8 = undefined;
    var part_count: usize = 0;
    var start: usize = 0;

    for (param_str, 0..) |c, i| {
        if (c == ';') {
            if (part_count >= 3) return MouseError.InvalidFormat;
            parts[part_count] = param_str[start..i];
            part_count += 1;
            start = i + 1;
        }
    }
    if (part_count >= 3) return MouseError.InvalidFormat;
    parts[part_count] = param_str[start..];
    part_count += 1;

    if (part_count != 3) return MouseError.InvalidFormat;

    const cb = parseU16(parts[0]) orelse return MouseError.InvalidNumber;
    const cx = parseU16(parts[1]) orelse return MouseError.InvalidNumber;
    const cy = parseU16(parts[2]) orelse return MouseError.InvalidNumber;

    // Decode button from Cb
    const button_bits: u8 = @intCast(cb & 0x03);
    const is_scroll = (cb & 64) != 0;
    const is_motion = (cb & 32) != 0;

    const button: MouseButton = if (is_scroll) blk: {
        break :blk if (button_bits == 0) .scroll_up else .scroll_down;
    } else switch (button_bits) {
        0 => .left,
        1 => .middle,
        2 => .right,
        3 => .none,
        else => .none,
    };

    const action: MouseAction = if (is_motion)
        .motion
    else if (is_release)
        .release
    else
        .press;

    const modifiers = Modifiers{
        .shift = (cb & 4) != 0,
        .alt = (cb & 8) != 0,
        .ctrl = (cb & 16) != 0,
    };

    return MouseEvent{
        .button = button,
        .action = action,
        .col = cx,
        .row = cy,
        .modifiers = modifiers,
    };
}

pub const SgrResult = struct { buf: [32]u8, len: usize };

/// Encode a mouse event to SGR format.
/// Returns the parameter bytes (e.g., "0;10;5M") and their length.
pub fn encodeSgrMouse(event: MouseEvent) SgrResult {
    var buf: [32]u8 = .{0} ** 32;

    var cb: u16 = switch (event.button) {
        .left => 0,
        .middle => 1,
        .right => 2,
        .scroll_up => 64,
        .scroll_down => 65,
        .none => 3,
    };

    if (event.modifiers.shift) cb |= 4;
    if (event.modifiers.alt) cb |= 8;
    if (event.modifiers.ctrl) cb |= 16;
    if (event.action == .motion) cb |= 32;

    const terminator: u8 = if (event.action == .release) 'm' else 'M';

    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    writer.print("{d};{d};{d}{c}", .{ cb, event.col, event.row, terminator }) catch {};

    return .{ .buf = buf, .len = stream.pos };
}

fn parseU16(s: []const u8) ?u16 {
    if (s.len == 0) return null;
    var result: u16 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        result = result *% 10 +% @as(u16, c - '0');
    }
    return result;
}
