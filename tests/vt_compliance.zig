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

// --- Observer hooks ---

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

// --- Resize ---

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

// --- Agent status effects (OSC 7501 / 9 / 777 / 9;4 / bell / query replies) ---

const StatusRec = struct {
    var status_count: usize = 0;
    var last_state: observer_mod.StatusReport.State = .idle;
    var last_kind: ?observer_mod.StatusReport.Kind = null;
    var last_id: [64]u8 = undefined;
    var last_id_len: usize = 0;
    var last_app: [64]u8 = undefined;
    var last_app_len: usize = 0;
    var last_msg: [256]u8 = undefined;
    var last_msg_len: usize = 0;
    var notify_count: usize = 0;
    var notify_body: [256]u8 = undefined;
    var notify_body_len: usize = 0;
    var bells: usize = 0;
    var prompts: usize = 0;
    var written: [512]u8 = undefined;
    var written_len: usize = 0;

    fn reset() void {
        status_count = 0;
        notify_count = 0;
        bells = 0;
        prompts = 0;
        written_len = 0;
    }

    fn copy(dst: []u8, src: []const u8) usize {
        const n = @min(dst.len, src.len);
        @memcpy(dst[0..n], src[0..n]);
        return n;
    }

    fn onStatus(_: ?*anyopaque, r: observer_mod.StatusReport) void {
        status_count += 1;
        last_state = r.state;
        last_kind = r.kind;
        last_id_len = copy(&last_id, r.id);
        last_app_len = copy(&last_app, r.app);
        last_msg_len = copy(&last_msg, r.msg);
    }
    fn onNotification(_: ?*anyopaque, _: []const u8, body: []const u8) void {
        notify_count += 1;
        notify_body_len = copy(&notify_body, body);
    }
    fn onBell(_: ?*anyopaque) void {
        bells += 1;
    }
    fn onPrompt(_: ?*anyopaque) void {
        prompts += 1;
    }
    fn onWrite(_: ?*anyopaque, data: []const u8) void {
        written_len += copy(written[written_len..], data);
    }

    fn wire(t: *PTermTerminal) void {
        reset();
        t.observer.onStatus = &onStatus;
        t.observer.onNotification = &onNotification;
        t.observer.onBell = &onBell;
        t.observer.onPromptStart = &onPrompt;
        t.observer.onWritePty = &onWrite;
    }
};

test "OSC 7501 report reaches onStatus with decoded fields" {
    var t = try createTestTerminal();
    defer t.deinit();
    StatusRec.wire(&t);

    try t.feedBytes("\x1b]7501;state=blocked:kind=permission:app=codex:msg=QXBwcm92ZSBlZGl0Pw==\x1b\\");
    try testing.expectEqual(@as(usize, 1), StatusRec.status_count);
    try testing.expectEqual(observer_mod.StatusReport.State.blocked, StatusRec.last_state);
    try testing.expectEqual(observer_mod.StatusReport.Kind.permission, StatusRec.last_kind.?);
    try testing.expectEqualStrings("codex", StatusRec.last_app[0..StatusRec.last_app_len]);
    try testing.expectEqualStrings("Approve edit?", StatusRec.last_msg[0..StatusRec.last_msg_len]);
    try testing.expectEqualStrings("", StatusRec.last_id[0..StatusRec.last_id_len]);

    // Split across reads, BEL-terminated, with an id.
    try t.feedBytes("\x1b]7501;state=wor");
    try t.feedBytes("king:id=ses_1\x07");
    try testing.expectEqual(@as(usize, 2), StatusRec.status_count);
    try testing.expectEqual(observer_mod.StatusReport.State.working, StatusRec.last_state);
    try testing.expectEqualStrings("ses_1", StatusRec.last_id[0..StatusRec.last_id_len]);
    // The BEL terminating the OSC is not a bell.
    try testing.expectEqual(@as(usize, 0), StatusRec.bells);
}

test "OSC 7501 support query is answered before DA1" {
    var t = try createTestTerminal();
    defer t.deinit();
    StatusRec.wire(&t);

    try t.feedBytes("\x1b]7501;?\x1b\\\x1b[c");
    const out = StatusRec.written[0..StatusRec.written_len];
    const status_reply = std.mem.indexOf(u8, out, "\x1b]7501;?") orelse return error.NoStatusReply;
    const da1_reply = std.mem.indexOf(u8, out, "\x1b[?") orelse return error.NoDa1Reply;
    try testing.expect(status_reply < da1_reply);
}

test "OSC 9;4 progress maps to a working record and clear" {
    var t = try createTestTerminal();
    defer t.deinit();
    StatusRec.wire(&t);

    try t.feedBytes("\x1b]9;4;1;50\x07");
    try testing.expectEqual(observer_mod.StatusReport.State.working, StatusRec.last_state);
    try testing.expectEqualStrings(terminal_mod.progress_record_id, StatusRec.last_id[0..StatusRec.last_id_len]);
    try t.feedBytes("\x1b]9;4;0\x07");
    try testing.expectEqual(observer_mod.StatusReport.State.clear, StatusRec.last_state);
}

test "OSC 9 and 777 notifications reach onNotification" {
    var t = try createTestTerminal();
    defer t.deinit();
    StatusRec.wire(&t);

    try t.feedBytes("\x1b]9;Agent turn complete\x07");
    try testing.expectEqual(@as(usize, 1), StatusRec.notify_count);
    try testing.expectEqualStrings("Agent turn complete", StatusRec.notify_body[0..StatusRec.notify_body_len]);
    try t.feedBytes("\x1b]777;notify;Gemini;Action required\x07");
    try testing.expectEqual(@as(usize, 2), StatusRec.notify_count);
    try testing.expectEqualStrings("Action required", StatusRec.notify_body[0..StatusRec.notify_body_len]);
    // ConEmu cwd report is not a notification.
    try t.feedBytes("\x1b]9;9;C:\\Users\\me\x07");
    try testing.expectEqual(@as(usize, 2), StatusRec.notify_count);
}

test "title updates are not bells; real BEL is" {
    var t = try createTestTerminal();
    defer t.deinit();
    StatusRec.wire(&t);

    try t.feedBytes("\x1b]0;\xe2\xa0\x8b working\x07");
    try testing.expectEqual(@as(usize, 0), StatusRec.bells);
    try t.feedBytes("\x07");
    try testing.expectEqual(@as(usize, 1), StatusRec.bells);
}

test "OSC 133;A reaches onPromptStart" {
    var t = try createTestTerminal();
    defer t.deinit();
    StatusRec.wire(&t);

    try t.feedBytes("\x1b]133;A\x07$ ");
    try testing.expectEqual(@as(usize, 1), StatusRec.prompts);
}
