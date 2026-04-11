const std = @import("std");
const testing = std.testing;
const ghostty_vt = @import("ghostty-vt");
const terminal_mod = @import("core_terminal");
const observer_mod = @import("core_observer");
const PTermTerminal = terminal_mod.PTermTerminal;
const Config = terminal_mod.Config;

fn createTestTerminal() !PTermTerminal {
    return try PTermTerminal.init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
    });
}

// --- Basic text output ---

test "basic text output" {
    var t = try createTestTerminal();
    defer t.deinit();

    try t.feedBytes("Hello");
    const str = try t.getScreenText();
    defer testing.allocator.free(str);

    try testing.expect(std.mem.indexOf(u8, str, "Hello") != null);
}

test "multiple lines" {
    var t = try createTestTerminal();
    defer t.deinit();

    try t.feedBytes("line1\r\nline2");
    const str = try t.getScreenText();
    defer testing.allocator.free(str);

    try testing.expect(std.mem.indexOf(u8, str, "line1") != null);
    try testing.expect(std.mem.indexOf(u8, str, "line2") != null);
}

// --- Cursor movement (CSI sequences) ---

test "cursor home position" {
    var t = try createTestTerminal();
    defer t.deinit();

    // Move cursor to row 5, col 10 (1-indexed in VT, 0-indexed internally)
    try t.feedBytes("\x1b[5;10H");
    const pos = t.getCursorPos();
    // VT uses 1-based; ghostty-vt stores 0-based
    try testing.expectEqual(@as(usize, 4), pos.row);
    try testing.expectEqual(@as(usize, 9), pos.col);
}

test "cursor move down" {
    var t = try createTestTerminal();
    defer t.deinit();

    try t.feedBytes("\x1b[3B"); // Move down 3
    const pos = t.getCursorPos();
    try testing.expectEqual(@as(usize, 3), pos.row);
}

test "cursor move right" {
    var t = try createTestTerminal();
    defer t.deinit();

    try t.feedBytes("\x1b[5C"); // Move right 5
    const pos = t.getCursorPos();
    try testing.expectEqual(@as(usize, 5), pos.col);
}

// --- SGR attributes ---

test "SGR bold sets style" {
    var t = try createTestTerminal();
    defer t.deinit();

    // Set bold, write char
    try t.feedBytes("\x1b[1mB");

    // The cell at (0,0) should have a non-zero style_id (bold applied)
    const screens = t.getScreens();
    const pin = screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 0 } });
    if (pin) |p| {
        const cell = p.rowAndCell().cell;
        // Bold text should have a style applied
        try testing.expect(cell.style_id != 0);
    }
}

test "SGR reset clears style" {
    var t = try createTestTerminal();
    defer t.deinit();

    // Set bold, then reset, then write char
    try t.feedBytes("\x1b[1m\x1b[0mN");

    const screens = t.getScreens();
    const pin = screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 0 } });
    if (pin) |p| {
        const cell = p.rowAndCell().cell;
        // After reset, style should be default (0)
        try testing.expectEqual(@as(u16, 0), cell.style_id);
    }
}

// --- True color 24-bit (CORE-03) ---

test "true color 24-bit foreground (CORE-03)" {
    var t = try createTestTerminal();
    defer t.deinit();

    // Set 24-bit fg color: RGB(255, 128, 0), then write char
    try t.feedBytes("\x1b[38;2;255;128;0mX");

    // Cell should have a style applied (non-zero style_id means color set)
    const screens = t.getScreens();
    const pin = screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 0 } });
    if (pin) |p| {
        const cell = p.rowAndCell().cell;
        try testing.expect(cell.style_id != 0);
        try testing.expectEqual(@as(u21, 'X'), cell.codepoint());

        // Look up actual style from page's style table via Pin helper
        const s = p.style(cell);
        // Verify fg is RGB and has correct values
        switch (s.fg_color) {
            .rgb => |rgb| {
                try testing.expectEqual(@as(u8, 255), rgb.r);
                try testing.expectEqual(@as(u8, 128), rgb.g);
                try testing.expectEqual(@as(u8, 0), rgb.b);
            },
            else => return error.TestUnexpectedResult,
        }
    } else {
        return error.TestUnexpectedResult;
    }
}

test "true color 24-bit background (CORE-03)" {
    var t = try createTestTerminal();
    defer t.deinit();

    // Set 24-bit bg color: RGB(0, 100, 200), then write char
    try t.feedBytes("\x1b[48;2;0;100;200mY");

    const screens = t.getScreens();
    const pin = screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 0 } });
    if (pin) |p| {
        const cell = p.rowAndCell().cell;
        try testing.expect(cell.style_id != 0);
        try testing.expectEqual(@as(u21, 'Y'), cell.codepoint());

        // Look up actual style from page's style table via Pin helper
        const s = p.style(cell);
        // Verify bg is RGB and has correct values
        switch (s.bg_color) {
            .rgb => |rgb| {
                try testing.expectEqual(@as(u8, 0), rgb.r);
                try testing.expectEqual(@as(u8, 100), rgb.g);
                try testing.expectEqual(@as(u8, 200), rgb.b);
            },
            else => return error.TestUnexpectedResult,
        }
    } else {
        return error.TestUnexpectedResult;
    }
}

test "SGR 256 color" {
    var t = try createTestTerminal();
    defer t.deinit();

    // Set 256-color fg (color 196 = red), then write char
    try t.feedBytes("\x1b[38;5;196mR");

    const screens = t.getScreens();
    const pin = screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 0 } });
    if (pin) |p| {
        const cell = p.rowAndCell().cell;
        try testing.expect(cell.style_id != 0);
        try testing.expectEqual(@as(u21, 'R'), cell.codepoint());
    }
}

// --- Observer hooks (D-06) ---

var observer_called: bool = false;
var observer_bytes_len: usize = 0;

fn testOutputCallback(bytes: []const u8) void {
    observer_called = true;
    observer_bytes_len = bytes.len;
}

test "observer callback fires on feedBytes" {
    var t = try createTestTerminal();
    defer t.deinit();

    observer_called = false;
    observer_bytes_len = 0;
    t.observer.onOutput = &testOutputCallback;

    try t.feedBytes("test");

    try testing.expect(observer_called);
    try testing.expectEqual(@as(usize, 4), observer_bytes_len);
}

var screen_change_called: bool = false;

fn testScreenChangeCallback(_: ?*anyopaque) void {
    screen_change_called = true;
}

test "observer screen change fires after feedBytes" {
    var t = try createTestTerminal();
    defer t.deinit();

    screen_change_called = false;
    t.observer.onScreenChange = &testScreenChangeCallback;

    try t.feedBytes("x");

    try testing.expect(screen_change_called);
}

// --- Resize (D-10) ---

test "terminal resize" {
    var t = try createTestTerminal();
    defer t.deinit();

    try t.resize(120, 40);

    try testing.expectEqual(@as(u16, 120), t.config.cols);
    try testing.expectEqual(@as(u16, 40), t.config.rows);
}

// --- Tab and special characters ---

test "tab character advances cursor" {
    var t = try createTestTerminal();
    defer t.deinit();

    try t.feedBytes("\t");
    const pos = t.getCursorPos();
    // Default tab stop is 8
    try testing.expectEqual(@as(usize, 8), pos.col);
}

test "carriage return moves cursor to column 0" {
    var t = try createTestTerminal();
    defer t.deinit();

    try t.feedBytes("hello\r");
    const pos = t.getCursorPos();
    try testing.expectEqual(@as(usize, 0), pos.col);
}

// --- Config ---

test "default config values" {
    const cfg = Config{};
    try testing.expectEqual(@as(u16, 80), cfg.cols);
    try testing.expectEqual(@as(u16, 24), cfg.rows);
    try testing.expectEqual(@as(u32, 10_000), cfg.scrollback_lines);
    try testing.expect(cfg.utf8_only);
}

// --- Observer onSequence ---

test "observer onSequence field exists and notify handles sequence event" {
    const obs = observer_mod.Observer{};
    // Default is null
    try testing.expectEqual(
        @as(?*const fn (u8, []const u16) void, null),
        obs.onSequence,
    );
    // Notify with sequence event should not crash (no callback set)
    const params = [_]u16{ 1, 2, 3 };
    obs.notify(.{ .sequence = .{ .action = 'H', .params = &params } });
}

var sequence_action_seen: u8 = 0;
var sequence_params_len_seen: usize = 0;

fn testSequenceCallback(action: u8, params: []const u16) void {
    sequence_action_seen = action;
    sequence_params_len_seen = params.len;
}

test "observer onSequence callback fires when set" {
    var obs = observer_mod.Observer{};
    obs.onSequence = &testSequenceCallback;

    sequence_action_seen = 0;
    sequence_params_len_seen = 0;

    const params = [_]u16{ 5, 10 };
    obs.notify(.{ .sequence = .{ .action = 'A', .params = &params } });

    try testing.expectEqual(@as(u8, 'A'), sequence_action_seen);
    try testing.expectEqual(@as(usize, 2), sequence_params_len_seen);
}
