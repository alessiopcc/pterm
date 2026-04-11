/// TOML config file loader with import chain resolution and deep merge.
///
/// Supports:
///   - Loading TOML files and mapping to Config struct
///   - `import = [...]` directive for parent config inheritance
///   - Cycle detection via visited path set
///   - Max import depth (10) to prevent runaway chains
///   - Missing import files log warning and continue
///   - Child config overrides parent (last-writer-wins per field)
const std = @import("std");
const toml = @import("toml");
const Config = @import("Config.zig").Config;
const layout_mod = @import("layout");
const LayoutPreset = layout_mod.LayoutPreset;

pub const LoadError = error{
    ImportCycleDetected,
    ImportDepthExceeded,
    FileNotFound,
    ParseError,
    OutOfMemory,
    InvalidValueType,
    MissingRequiredField,
    NotSupportedFieldType,
    InvalidArrayLength,
    Overflow,
};

const max_import_depth: u8 = 10;

/// TOML-friendly config struct. Uses types the TOML parser can handle directly.
/// The sam701/zig-toml library maps TOML integers to i64 and floats to f64,
/// so we use those types here and convert in the final Config.
const FileFont = struct {
    family: ?[]const u8 = null,
    size: f64 = 13.0,
};

const FileWindow = struct {
    title: ?[]const u8 = null,
    cols: i64 = 160,
    rows: i64 = 48,
    padding: f64 = 4.0,
    opacity: f64 = 1.0,
};

const FileCursor = struct {
    style: ?[]const u8 = null,
    blink: bool = true,
};

const FileScrollback = struct {
    lines: i64 = 10_000,
};

const FileShell = struct {
    program: ?[]const u8 = null,
    working_dir: ?[]const u8 = null,
};

const FileUiColors = struct {
    tab_bar_bg: ?[]const u8 = null,
    tab_active: ?[]const u8 = null,
    tab_inactive: ?[]const u8 = null,
    pane_border: ?[]const u8 = null,
    pane_border_active: ?[]const u8 = null,
    status_bar_bg: ?[]const u8 = null,
    agent_alert: ?[]const u8 = null,
    // Phase 6: search, URL, bell UI colors
    search_bar_bg: ?[]const u8 = null,
    search_match: ?[]const u8 = null,
    search_current_match: ?[]const u8 = null,
    url_hover: ?[]const u8 = null,
    bell_flash: ?[]const u8 = null,
    bell_badge: ?[]const u8 = null,
};

const FileColors = struct {
    foreground: ?[]const u8 = null,
    background: ?[]const u8 = null,
    cursor_color: ?[]const u8 = null,
    cursor_text: ?[]const u8 = null,
    selection_bg: ?[]const u8 = null,
    selection_fg: ?[]const u8 = null,
    ui: ?FileUiColors = null,
};

const FileSearch = struct {};

const FileUrl = struct {
    enabled: bool = true,
};

const FileBell = struct {
    mode: ?[]const u8 = null,
};

const FileConfig = struct {
    import: ?[]const []const u8 = null,
    font: ?FileFont = null,
    window: ?FileWindow = null,
    cursor: ?FileCursor = null,
    scrollback: ?FileScrollback = null,
    shell: ?FileShell = null,
    colors: ?FileColors = null,
    search: ?FileSearch = null,
    url: ?FileUrl = null,
    bell: ?FileBell = null,
};

/// Load a config file and resolve its import chain, returning a merged Config.
pub fn loadConfigFromPath(allocator: std.mem.Allocator, path: []const u8) LoadError!Config {
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var it = visited.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        visited.deinit();
    }
    return loadFile(allocator, path, 0, &visited);
}

/// Load a single TOML file at the given depth in the import chain.
pub fn loadFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    depth: u8,
    visited: *std.StringHashMap(void),
) LoadError!Config {
    if (depth > max_import_depth) return error.ImportDepthExceeded;

    // Canonicalize path for cycle detection
    const canon_path = allocator.dupe(u8, path) catch return error.OutOfMemory;

    // Check for cycles
    if (visited.contains(canon_path)) {
        allocator.free(canon_path);
        return error.ImportCycleDetected;
    }
    visited.put(canon_path, {}) catch return error.OutOfMemory;

    // Read file contents
    const content = readFileContents(allocator, path) catch |err| {
        switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => {
                std.log.warn("Failed to read config file {s}: {}", .{ path, err });
                return error.FileNotFound;
            },
        }
    };
    defer allocator.free(content);

    // Parse TOML into FileConfig
    var parser = toml.Parser(FileConfig).init(allocator);
    defer parser.deinit();

    var result = parser.parseString(content) catch {
        std.log.warn("Failed to parse TOML in {s}", .{path});
        return error.ParseError;
    };
    defer result.deinit();

    const file_cfg = result.value;

    // Start with defaults as base
    var config = Config.defaults();

    // Process imports first (imported configs provide base, current file overrides)
    if (file_cfg.import) |imports| {
        for (imports) |import_path| {
            const resolved = resolveImportPath(allocator, path, import_path) catch |err| {
                std.log.warn("Failed to resolve import path {s} from {s}: {}", .{ import_path, path, err });
                continue;
            };
            defer allocator.free(resolved);

            const imported = loadFile(allocator, resolved, depth + 1, visited) catch |err| {
                switch (err) {
                    error.FileNotFound => {
                        std.log.warn("Import file not found: {s} (from {s}), skipping", .{ import_path, path });
                        continue;
                    },
                    error.ImportCycleDetected => {
                        std.log.warn("Import cycle detected involving {s}, skipping", .{import_path});
                        return error.ImportCycleDetected;
                    },
                    else => {
                        std.log.warn("Failed to load import {s}: {}", .{ import_path, err });
                        continue;
                    },
                }
            };
            config = mergeConfigs(config, imported);
        }
    }

    // Apply current file's values (overriding imported base)
    // Must dupe strings before result.deinit() frees the TOML arena.
    config = applyFileConfig(allocator, config, file_cfg) catch return error.OutOfMemory;

    // Parse [keybindings] section manually (dynamic keys, not in FileConfig)
    config.keybindings = parseKeybindingsSection(allocator, content) catch &.{};

    // Parse [layout.*] sections manually (dynamic preset names, not in FileConfig)
    config.layouts = LayoutPreset.parsePresets(allocator, content) catch |err| blk: {
        std.log.warn("Failed to parse layout presets: {}", .{err});
        break :blk &.{};
    };

    return config;
}

/// Merge two configs: `over` overrides `base`.
fn mergeConfigs(base: Config, over: Config) Config {
    var result = base;

    // Font
    if (over.font.family) |v| result.font.family = v;
    if (over.font.size != Config.default_font_size) result.font.size = over.font.size;

    // Window
    if (!std.mem.eql(u8, over.window.title, "PTerm")) result.window.title = over.window.title;
    if (over.window.cols != Config.default_cols) result.window.cols = over.window.cols;
    if (over.window.rows != Config.default_rows) result.window.rows = over.window.rows;
    if (over.window.padding != Config.default_padding) result.window.padding = over.window.padding;
    if (over.window.opacity != Config.default_opacity) result.window.opacity = over.window.opacity;

    // Cursor
    if (over.cursor.style != .block) result.cursor.style = over.cursor.style;
    if (!over.cursor.blink) result.cursor.blink = over.cursor.blink;

    // Scrollback
    if (over.scrollback.lines != Config.default_scrollback) result.scrollback.lines = over.scrollback.lines;

    // Shell
    if (over.shell.program) |v| result.shell.program = v;
    if (over.shell.working_dir) |v| result.shell.working_dir = v;

    // Colors
    if (over.colors.foreground) |v| result.colors.foreground = v;
    if (over.colors.background) |v| result.colors.background = v;
    if (over.colors.cursor_color) |v| result.colors.cursor_color = v;
    if (over.colors.cursor_text) |v| result.colors.cursor_text = v;
    if (over.colors.selection_bg) |v| result.colors.selection_bg = v;
    if (over.colors.selection_fg) |v| result.colors.selection_fg = v;

    // UI Colors
    if (over.colors.ui.tab_bar_bg) |v| result.colors.ui.tab_bar_bg = v;
    if (over.colors.ui.tab_active) |v| result.colors.ui.tab_active = v;
    if (over.colors.ui.tab_inactive) |v| result.colors.ui.tab_inactive = v;
    if (over.colors.ui.pane_border) |v| result.colors.ui.pane_border = v;
    if (over.colors.ui.pane_border_active) |v| result.colors.ui.pane_border_active = v;
    if (over.colors.ui.status_bar_bg) |v| result.colors.ui.status_bar_bg = v;
    if (over.colors.ui.agent_alert) |v| result.colors.ui.agent_alert = v;
    if (over.colors.ui.search_bar_bg) |v| result.colors.ui.search_bar_bg = v;
    if (over.colors.ui.search_match) |v| result.colors.ui.search_match = v;
    if (over.colors.ui.search_current_match) |v| result.colors.ui.search_current_match = v;
    if (over.colors.ui.url_hover) |v| result.colors.ui.url_hover = v;
    if (over.colors.ui.bell_flash) |v| result.colors.ui.bell_flash = v;
    if (over.colors.ui.bell_badge) |v| result.colors.ui.bell_badge = v;

    // Agent notification fields (Phase 8)
    if (!over.agent.notifications) result.agent.notifications = over.agent.notifications;
    if (!over.agent.notification_sound) result.agent.notification_sound = over.agent.notification_sound;
    if (over.agent.notification_cooldown != 30) result.agent.notification_cooldown = over.agent.notification_cooldown;
    if (!over.agent.suppress_when_focused) result.agent.suppress_when_focused = over.agent.suppress_when_focused;

    // Bell
    if (over.bell.mode != .visual) result.bell.mode = over.bell.mode;

    // URL
    if (!over.url.enabled) result.url.enabled = over.url.enabled;

    return result;
}

/// Apply FileConfig values onto a Config (current file overriding base).
/// Duplicates all string values into the allocator so they outlive the TOML arena.
fn applyFileConfig(allocator: std.mem.Allocator, base: Config, file: FileConfig) !Config {
    var result = base;

    if (file.font) |f| {
        if (f.family) |v| result.font.family = try allocator.dupe(u8, v);
        if (f.size != 13.0) result.font.size = @floatCast(f.size);
    }

    if (file.window) |w| {
        if (w.title) |v| result.window.title = try allocator.dupe(u8, v);
        if (w.cols != 160) result.window.cols = w.cols;
        if (w.rows != 48) result.window.rows = w.rows;
        if (w.padding != 4.0) result.window.padding = @floatCast(w.padding);
        if (w.opacity != 1.0) result.window.opacity = @floatCast(w.opacity);
    }

    if (file.cursor) |c| {
        if (c.style) |s| {
            if (std.mem.eql(u8, s, "bar")) {
                result.cursor.style = .bar;
            } else if (std.mem.eql(u8, s, "underline")) {
                result.cursor.style = .underline;
            } else if (std.mem.eql(u8, s, "block")) {
                result.cursor.style = .block;
            } else {
                std.log.warn("Unknown cursor style: {s}, using default", .{s});
            }
        }
        if (!c.blink) result.cursor.blink = false;
    }

    if (file.scrollback) |s| {
        if (s.lines != 10_000) result.scrollback.lines = s.lines;
    }

    if (file.shell) |s| {
        if (s.program) |v| result.shell.program = try allocator.dupe(u8, v);
        if (s.working_dir) |v| result.shell.working_dir = try allocator.dupe(u8, v);
    }

    if (file.colors) |c| {
        if (c.foreground) |v| result.colors.foreground = try allocator.dupe(u8, v);
        if (c.background) |v| result.colors.background = try allocator.dupe(u8, v);
        if (c.cursor_color) |v| result.colors.cursor_color = try allocator.dupe(u8, v);
        if (c.cursor_text) |v| result.colors.cursor_text = try allocator.dupe(u8, v);
        if (c.selection_bg) |v| result.colors.selection_bg = try allocator.dupe(u8, v);
        if (c.selection_fg) |v| result.colors.selection_fg = try allocator.dupe(u8, v);

        if (c.ui) |ui| {
            if (ui.tab_bar_bg) |v| result.colors.ui.tab_bar_bg = try allocator.dupe(u8, v);
            if (ui.tab_active) |v| result.colors.ui.tab_active = try allocator.dupe(u8, v);
            if (ui.tab_inactive) |v| result.colors.ui.tab_inactive = try allocator.dupe(u8, v);
            if (ui.pane_border) |v| result.colors.ui.pane_border = try allocator.dupe(u8, v);
            if (ui.pane_border_active) |v| result.colors.ui.pane_border_active = try allocator.dupe(u8, v);
            if (ui.status_bar_bg) |v| result.colors.ui.status_bar_bg = try allocator.dupe(u8, v);
            if (ui.agent_alert) |v| result.colors.ui.agent_alert = try allocator.dupe(u8, v);
            if (ui.search_bar_bg) |v| result.colors.ui.search_bar_bg = try allocator.dupe(u8, v);
            if (ui.search_match) |v| result.colors.ui.search_match = try allocator.dupe(u8, v);
            if (ui.search_current_match) |v| result.colors.ui.search_current_match = try allocator.dupe(u8, v);
            if (ui.url_hover) |v| result.colors.ui.url_hover = try allocator.dupe(u8, v);
            if (ui.bell_flash) |v| result.colors.ui.bell_flash = try allocator.dupe(u8, v);
            if (ui.bell_badge) |v| result.colors.ui.bell_badge = try allocator.dupe(u8, v);
        }
    }

    // Bell
    if (file.bell) |b| {
        if (b.mode) |mode_str| {
            if (std.mem.eql(u8, mode_str, "visual")) {
                result.bell.mode = .visual;
            } else if (std.mem.eql(u8, mode_str, "sound")) {
                result.bell.mode = .sound;
            } else if (std.mem.eql(u8, mode_str, "both")) {
                result.bell.mode = .both;
            } else if (std.mem.eql(u8, mode_str, "none")) {
                result.bell.mode = .none;
            } else {
                std.log.warn("Unknown bell mode: {s}, using default", .{mode_str});
            }
        }
    }

    // URL
    if (file.url) |u| {
        if (!u.enabled) result.url.enabled = false;
    }

    return result;
}

/// Resolve an import path relative to the importing file's directory.
fn resolveImportPath(allocator: std.mem.Allocator, base_file: []const u8, import_path: []const u8) ![]const u8 {
    // If import_path is absolute, use as-is
    if (import_path.len > 0 and (import_path[0] == '/' or
        (import_path.len > 1 and import_path[1] == ':')))
    {
        return allocator.dupe(u8, import_path);
    }

    // Expand ~ to HOME
    if (import_path.len > 0 and import_path[0] == '~') {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch
            std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
            return allocator.dupe(u8, import_path);
        defer allocator.free(home);
        const rest = if (import_path.len > 1) import_path[1..] else "";
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, rest });
    }

    // Relative: resolve against the directory of the importing file
    const dir = dirName(base_file);
    if (dir.len == 0) {
        return allocator.dupe(u8, import_path);
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, import_path });
}

/// Get the directory portion of a file path.
fn dirName(path: []const u8) []const u8 {
    // Find last separator
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') {
            return path[0..i];
        }
    }
    return "";
}

/// Parse [keybindings] section from raw TOML content into KeybindingEntry slice.
fn parseKeybindingsSection(allocator: std.mem.Allocator, content: []const u8) ![]const Config.KeybindingEntry {
    var entries: std.ArrayListUnmanaged(Config.KeybindingEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.action_name);
            allocator.free(e.combo_str);
        }
        entries.deinit(allocator);
    }

    var in_section = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (trimmed[0] == '[') {
            in_section = std.mem.startsWith(u8, trimmed, "[keybindings]");
            continue;
        }
        if (!in_section) continue;

        const eq_idx = std.mem.indexOf(u8, trimmed, "=") orelse continue;
        const action_name = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
        var value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");

        // Handle array syntax: take first element
        if (value.len > 0 and value[0] == '[') {
            value = std.mem.trim(u8, value, "[]");
            if (std.mem.indexOf(u8, value, ",")) |comma| {
                value = value[0..comma];
            }
        }
        const combo_str = std.mem.trim(u8, value, " \t\"'");
        if (combo_str.len == 0) continue;

        try entries.append(allocator, .{
            .action_name = try allocator.dupe(u8, action_name),
            .combo_str = try allocator.dupe(u8, combo_str),
        });
    }

    return entries.toOwnedSlice(allocator);
}

/// Read entire file contents into an allocator-owned slice.
fn readFileContents(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => error.FileNotFound,
            else => error.FileNotFound,
        };
    };
    defer file.close();

    const stat = file.stat() catch return error.FileNotFound;
    const size = stat.size;
    if (size == 0) return allocator.dupe(u8, "");
    if (size > 10 * 1024 * 1024) return error.FileNotFound; // 10MB max

    const buf = allocator.alloc(u8, size) catch return error.OutOfMemory;
    errdefer allocator.free(buf);

    const read = file.readAll(buf) catch return error.FileNotFound;
    if (read != size) {
        // Partial read -- resize
        const trimmed = allocator.realloc(buf, read) catch return buf[0..read];
        return trimmed;
    }
    return buf;
}
