/// Interactive TUI for keybinding configuration (D-22).
///
/// `pterm --set-keybindings` launches this mode. Shows all actions with their
/// current bindings, lets user type new combos as strings (e.g. "ctrl+n"),
/// and writes updated keybindings to config.toml.
///
/// Each action has exactly one combo (last assignment wins).
const std = @import("std");
const Allocator = std.mem.Allocator;
const kb = @import("keybindings");

const Action = kb.Action;
const KeyCombo = kb.KeyCombo;
const KeyId = kb.KeyId;
const Modifiers = kb.Modifiers;
const SpecialKey = kb.SpecialKey;

/// Format a KeyCombo back to its string representation (e.g., "ctrl+shift+t").
/// Writes into the provided buffer and returns the slice.
pub fn formatKeyCombo(combo: KeyCombo, buf: []u8) []const u8 {
    var pos: usize = 0;

    if (combo.mods.ctrl) pos = appendStr(buf, pos, "ctrl+");
    if (combo.mods.shift) pos = appendStr(buf, pos, "shift+");
    if (combo.mods.alt) pos = appendStr(buf, pos, "alt+");
    if (combo.mods.super) pos = appendStr(buf, pos, "super+");

    switch (combo.key) {
        .char => |c| {
            if (pos < buf.len) {
                buf[pos] = @intCast(c & 0x7F);
                pos += 1;
            }
        },
        .special => |s| {
            pos = appendStr(buf, pos, specialKeyName(s));
        },
    }

    return buf[0..pos];
}

/// Run the interactive keybinding configuration TUI.
pub fn run(allocator: Allocator, config_path: []const u8, _: ?[]const kb.UserBinding) !void {
    // Load existing keybindings from config file
    var loaded_bindings: std.ArrayListUnmanaged(kb.UserBinding) = .empty;
    defer {
        for (loaded_bindings.items) |b| {
            allocator.free(@constCast(b.combo_str));
            allocator.free(@constCast(b.action_name));
        }
        loaded_bindings.deinit(allocator);
    }
    loadKeybindingsFromConfig(allocator, config_path, &loaded_bindings) catch {};

    const bindings_slice: ?[]const kb.UserBinding = if (loaded_bindings.items.len > 0) loaded_bindings.items else null;
    var map = try kb.buildMap(allocator, bindings_slice);
    defer map.deinit();

    const ActionInfo = struct { action: Action, name: []const u8 };

    const actions = comptime blk: {
        const fields = @typeInfo(Action).@"enum".fields;
        var result: [fields.len]ActionInfo = undefined;
        for (fields, 0..) |f, i| {
            result[i] = .{ .action = @enumFromInt(f.value), .name = f.name };
        }
        break :blk result;
    };

    const stdin_file = std.fs.File{ .handle = if (@import("builtin").os.tag == .windows) blk: {
        const handle = std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_INPUT_HANDLE);
        break :blk handle orelse return error.StdinUnavailable;
    } else blk: {
        break :blk 0;
    } };

    var line_buf: [64]u8 = undefined;
    var modified = false;

    while (true) {
        // Build display index -> action index mapping
        var display_map: [actions.len]usize = undefined;
        var display_count: usize = 0;

        // Display menu each iteration
        std.debug.print("\n=== PTerm Keybinding Configuration ===\n\n", .{});

        for (actions, 0..) |info, i| {
            if (info.action == .none) continue;
            if (kb.isReservedAction(info.action)) continue;
            display_map[display_count] = i;
            display_count += 1;
            std.debug.print("  {d:>2}. {s:<24}", .{ display_count, info.name });

            var combo_buf: [64]u8 = undefined;
            var found = false;
            var iter = map.map.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.* == info.action) {
                    if (found) std.debug.print(", ", .{});
                    std.debug.print("{s}", .{formatKeyCombo(entry.key_ptr.*, &combo_buf)});
                    found = true;
                }
            }
            if (!found) std.debug.print("(unbound)", .{});
            std.debug.print("\n", .{});
        }

        if (modified) std.debug.print("\n  * unsaved changes\n", .{});
        std.debug.print("\nEnter action number, 's' to save, 'q' to quit: ", .{});

        const n = stdin_file.read(&line_buf) catch break;
        if (n == 0) break;
        const input = std.mem.trimRight(u8, line_buf[0..n], "\r\n ");
        if (input.len == 0) continue;

        if (std.mem.eql(u8, input, "q")) {
            if (modified) {
                std.debug.print("Discard changes? (y/n): ", .{});
                const n2 = stdin_file.read(&line_buf) catch break;
                const confirm = std.mem.trimRight(u8, line_buf[0..n2], "\r\n ");
                if (!std.mem.eql(u8, confirm, "y")) continue;
            }
            break;
        }

        if (std.mem.eql(u8, input, "s")) {
            try writeKeybindingsToConfig(allocator, config_path, &map);
            std.debug.print("\nSaved to {s}. Restart PTerm to apply.\n", .{config_path});
            modified = false;
            continue;
        }

        const num = std.fmt.parseInt(usize, input, 10) catch {
            std.debug.print("Invalid input.\n", .{});
            continue;
        };
        if (num < 1 or num > display_count) {
            std.debug.print("Out of range (1-{d}).\n", .{display_count});
            continue;
        }

        const selected = actions[display_map[num - 1]];

        std.debug.print("\nType combo for '{s}' (e.g. ctrl+n, shift+insert), or 'unbind', or 'cancel':\n> ", .{selected.name});

        const combo_n = stdin_file.read(&line_buf) catch break;
        if (combo_n == 0) break;
        const combo_input = std.mem.trimRight(u8, line_buf[0..combo_n], "\r\n ");
        if (combo_input.len == 0 or std.mem.eql(u8, combo_input, "cancel")) continue;

        // Remove ALL existing combos for this action first (1 combo per action)
        removeActionBindings(&map, selected.action);

        if (std.mem.eql(u8, combo_input, "unbind")) {
            std.debug.print("Unbound '{s}'.\n", .{selected.name});
            modified = true;
            continue;
        }

        const new_combo = kb.parseKeyCombo(combo_input) catch {
            std.debug.print("Invalid combo '{s}'. Use format: ctrl+n, shift+insert, alt+f1\n", .{combo_input});
            continue;
        };

        if (kb.isReservedClipboardKey(new_combo)) {
            std.debug.print("'{s}' is reserved for clipboard.\n", .{combo_input});
            continue;
        }

        // Remove any existing binding for this combo (steal from other action)
        if (map.get(new_combo)) |existing| {
            std.debug.print("(took '{s}' from {s})\n", .{ combo_input, @tagName(existing) });
        }

        try map.put(new_combo, selected.action);
        modified = true;

        var fmt_buf: [64]u8 = undefined;
        std.debug.print("Bound '{s}' = {s}\n", .{ selected.name, formatKeyCombo(new_combo, &fmt_buf) });
    }
}

/// Remove all combo->action entries for a given action from the map.
fn removeActionBindings(map: *kb.KeybindingMap, action: Action) void {
    map.removeByAction(action);
}

/// Write keybinding overrides to a TOML config file.
/// Creates or updates the [keybindings] section.
pub fn writeKeybindingsToConfig(allocator: Allocator, config_path: []const u8, map: *const kb.KeybindingMap) !void {
    var existing_content: []const u8 = "";
    var content_owned = false;
    if (std.fs.cwd().openFile(config_path, .{})) |file| {
        defer file.close();
        const stat = try file.stat();
        if (stat.size > 0 and stat.size < 1_000_000) {
            existing_content = try file.readToEndAlloc(allocator, 1_000_000);
            content_owned = true;
        }
    } else |_| {}
    defer if (content_owned) allocator.free(existing_content);

    var toml_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer toml_buf.deinit(allocator);

    // Copy existing content, stripping old [keybindings] section
    var in_keybindings_section = false;
    var lines = std.mem.splitScalar(u8, existing_content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "[keybindings]")) {
            in_keybindings_section = true;
            continue;
        }
        if (in_keybindings_section) {
            if (trimmed.len > 0 and trimmed[0] == '[') {
                in_keybindings_section = false;
            } else {
                continue;
            }
        }
        try toml_buf.appendSlice(allocator, line);
        try toml_buf.append(allocator, '\n');
    }

    // Append [keybindings] section — one combo per action
    try toml_buf.appendSlice(allocator, "\n[keybindings]\n");

    const fields = @typeInfo(Action).@"enum".fields;
    inline for (fields) |field| {
        const action: Action = @enumFromInt(field.value);
        if (action == .none) continue;

        var iter = map.map.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* == action) {
                var fmt_buf: [64]u8 = undefined;
                const formatted = formatKeyCombo(entry.key_ptr.*, &fmt_buf);
                try toml_buf.appendSlice(allocator, field.name);
                try toml_buf.appendSlice(allocator, " = \"");
                try toml_buf.appendSlice(allocator, formatted);
                try toml_buf.appendSlice(allocator, "\"\n");
                break; // One combo per action
            }
        }
    }

    const dir = std.fs.path.dirname(config_path);
    if (dir) |d| std.fs.cwd().makePath(d) catch {};
    const file = try std.fs.cwd().createFile(config_path, .{});
    defer file.close();
    try file.writeAll(toml_buf.items);
}

/// Parse [keybindings] section from a TOML config file into UserBinding entries.
/// Format: action_name = "combo" or action_name = ["combo1", "combo2"]
fn loadKeybindingsFromConfig(
    allocator: Allocator,
    config_path: []const u8,
    out: *std.ArrayListUnmanaged(kb.UserBinding),
) !void {
    const file = std.fs.cwd().openFile(config_path, .{}) catch return;
    defer file.close();
    const content = file.readToEndAlloc(allocator, 1_000_000) catch return;
    defer allocator.free(content);

    var in_section = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Detect section headers
        if (trimmed[0] == '[') {
            in_section = std.mem.startsWith(u8, trimmed, "[keybindings]");
            continue;
        }
        if (!in_section) continue;

        // Parse: action_name = "combo" or action_name = ["combo1", "combo2"]
        const eq_idx = std.mem.indexOf(u8, trimmed, "=") orelse continue;
        const action_name = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
        var value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");

        // Extract single combo string (strip quotes, array brackets)
        if (value.len > 0 and value[0] == '[') {
            // Array: take first element only
            value = std.mem.trim(u8, value, "[]");
            if (std.mem.indexOf(u8, value, ",")) |comma| {
                value = value[0..comma];
            }
        }
        const combo_str = std.mem.trim(u8, value, " \t\"'");
        if (combo_str.len == 0) continue;

        try out.append(allocator, .{
            .action_name = try allocator.dupe(u8, action_name),
            .combo_str = try allocator.dupe(u8, combo_str),
        });
    }
}

// -- Internal helpers --

fn appendStr(buf: []u8, pos: usize, str: []const u8) usize {
    const end = @min(pos + str.len, buf.len);
    @memcpy(buf[pos..end], str[0..copy_len(pos, end)]);
    return end;
}

fn copy_len(pos: usize, end: usize) usize {
    return end - pos;
}

fn specialKeyName(key: SpecialKey) []const u8 {
    return switch (key) {
        .insert => "insert",
        .delete => "delete",
        .home => "home",
        .end => "end",
        .page_up => "pageup",
        .page_down => "pagedown",
        .up => "up",
        .down => "down",
        .left => "left",
        .right => "right",
        .tab => "tab",
        .enter => "enter",
        .escape => "escape",
        .backspace => "backspace",
        .f1 => "f1",
        .f2 => "f2",
        .f3 => "f3",
        .f4 => "f4",
        .f5 => "f5",
        .f6 => "f6",
        .f7 => "f7",
        .f8 => "f8",
        .f9 => "f9",
        .f10 => "f10",
        .f11 => "f11",
        .f12 => "f12",
    };
}

// -------------------------------------------------------
// Inline Tests
// -------------------------------------------------------

test "formatKeyCombo: ctrl+c" {
    const combo = try kb.parseKeyCombo("ctrl+c");
    var buf: [64]u8 = undefined;
    const result = formatKeyCombo(combo, &buf);
    try std.testing.expectEqualSlices(u8, "ctrl+c", result);
}

test "formatKeyCombo: ctrl+shift+t" {
    const combo = try kb.parseKeyCombo("ctrl+shift+t");
    var buf: [64]u8 = undefined;
    const result = formatKeyCombo(combo, &buf);
    try std.testing.expectEqualSlices(u8, "ctrl+shift+t", result);
}

test "formatKeyCombo: shift+pageup" {
    const combo = try kb.parseKeyCombo("shift+pageup");
    var buf: [64]u8 = undefined;
    const result = formatKeyCombo(combo, &buf);
    try std.testing.expectEqualSlices(u8, "shift+pageup", result);
}

test "formatKeyCombo: super+c" {
    const combo = try kb.parseKeyCombo("super+c");
    var buf: [64]u8 = undefined;
    const result = formatKeyCombo(combo, &buf);
    try std.testing.expectEqualSlices(u8, "super+c", result);
}
