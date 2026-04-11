/// Configuration system for TermP.
///
/// Provides a four-tier config loading pipeline:
///   1. Built-in defaults (zero-friction first launch)
///   2. TOML config file (with import/merge support)
///   3. TERMP_* environment variable overrides
///   4. CLI flag overrides (highest priority)
///
/// After loading, validate() clamps invalid values to safe defaults.
const std = @import("std");
const loader = @import("loader");
const defaults_mod = @import("defaults");
const cli_mod = @import("cli");
const env_mod = @import("env");

pub const Config = struct {
    // [font]
    font: Font = .{},
    // [window]
    window: Window = .{},
    // [cursor]
    cursor: Cursor = .{},
    // [scrollback]
    scrollback: Scrollback = .{},
    // [shell]
    shell: Shell = .{},
    // [colors]
    colors: Colors = .{},
    // [keybindings] — raw action=combo pairs from TOML, passed to buildMap at runtime
    keybindings: []const KeybindingEntry = &.{},

    pub const KeybindingEntry = struct {
        action_name: []const u8,
        combo_str: []const u8,
    };

    pub const Font = struct {
        family: ?[]const u8 = null, // null = platform default
        size: f32 = 13.0,
    };

    pub const Window = struct {
        title: []const u8 = "TermP",
        cols: i64 = 160,
        rows: i64 = 48,
        padding: f32 = 4.0,
        opacity: f32 = 1.0,
    };

    pub const Cursor = struct {
        style: CursorStyle = .block,
        blink: bool = true,
    };

    pub const CursorStyle = enum { block, bar, underline };

    pub const Scrollback = struct {
        lines: i64 = 10_000,
    };

    pub const Shell = struct {
        program: ?[]const u8 = null, // null = auto-detect
        working_dir: ?[]const u8 = null,
    };

    pub const Colors = struct {
        foreground: ?[]const u8 = null,
        background: ?[]const u8 = null,
        cursor_color: ?[]const u8 = null,
        cursor_text: ?[]const u8 = null,
        selection_bg: ?[]const u8 = null,
        selection_fg: ?[]const u8 = null,
        ui: UiColors = .{},
    };

    /// Per D-28: UI chrome colors for tab bar, panes, status bar, agent alerts.
    /// Fields are schema stubs with sensible Catppuccin Mocha defaults.
    /// Not wired to UI rendering until Phase 5 (tabs/panes) and Phase 7 (agent alerts).
    /// MUST be present in schema now so config files and themes can define them.
    pub const UiColors = struct {
        tab_bar_bg: ?[]const u8 = null,
        tab_active: ?[]const u8 = null,
        tab_inactive: ?[]const u8 = null,
        pane_border: ?[]const u8 = null,
        status_bar_bg: ?[]const u8 = null,
        agent_alert: ?[]const u8 = null,
    };

    /// Default config path constants.
    pub const default_font_size: f32 = 13.0;
    pub const default_cols: i64 = 160;
    pub const default_rows: i64 = 48;
    pub const default_padding: f32 = 4.0;
    pub const default_opacity: f32 = 1.0;
    pub const default_scrollback: i64 = 10_000;
    pub const min_font_size: f32 = 4.0;
    pub const max_font_size: f32 = 128.0;
    pub const min_cols: i64 = 10;
    pub const max_cols: i64 = 1000;
    pub const min_rows: i64 = 4;
    pub const max_rows: i64 = 500;

    /// Return a Config with all defaults applied. Zero-cost: just returns .{}.
    pub fn defaults() Config {
        return .{};
    }

    /// Full four-tier loading pipeline.
    /// 1. defaults() -> 2. TOML file -> 3. env overrides -> 4. CLI overrides -> validate()
    pub fn load(allocator: std.mem.Allocator, cli_args: cli_mod.CliArgs) !Config {
        var config = Config.defaults();

        // Tier 2: Load TOML config file (if exists)
        const config_path = cli_args.config_path orelse defaults_mod.defaultConfigPath();
        if (config_path) |path| {
            if (loader.loadConfigFromPath(allocator, path)) |file_config| {
                config = mergeFileIntoConfig(config, file_config);
            } else |err| {
                switch (err) {
                    error.FileNotFound => {}, // Missing config = use defaults (zero-friction)
                    else => {
                        std.log.warn("Failed to load config from {s}: {}", .{ path, err });
                    },
                }
            }
        }

        // Tier 3: Environment variable overrides
        config = env_mod.applyOverrides(config);

        // Tier 4: CLI flag overrides
        config = cli_mod.applyOverrides(config, cli_args);

        // Validate and clamp
        config.validate();

        return config;
    }

    /// Merge a file-loaded Config (partial -- has optional fields) into a base Config.
    /// Non-null fields from `file` override `base`.
    fn mergeFileIntoConfig(base: Config, file: Config) Config {
        var result = base;

        // Font
        if (file.font.family) |v| result.font.family = v;
        if (file.font.size != default_font_size) result.font.size = file.font.size;

        // Window
        if (!std.mem.eql(u8, file.window.title, "TermP")) result.window.title = file.window.title;
        if (file.window.cols != default_cols) result.window.cols = file.window.cols;
        if (file.window.rows != default_rows) result.window.rows = file.window.rows;
        if (file.window.padding != default_padding) result.window.padding = file.window.padding;
        if (file.window.opacity != default_opacity) result.window.opacity = file.window.opacity;

        // Cursor
        if (file.cursor.style != .block) result.cursor.style = file.cursor.style;
        if (!file.cursor.blink) result.cursor.blink = file.cursor.blink;

        // Scrollback
        if (file.scrollback.lines != default_scrollback) result.scrollback.lines = file.scrollback.lines;

        // Shell
        if (file.shell.program) |v| result.shell.program = v;
        if (file.shell.working_dir) |v| result.shell.working_dir = v;

        // Colors
        if (file.colors.foreground) |v| result.colors.foreground = v;
        if (file.colors.background) |v| result.colors.background = v;
        if (file.colors.cursor_color) |v| result.colors.cursor_color = v;
        if (file.colors.cursor_text) |v| result.colors.cursor_text = v;
        if (file.colors.selection_bg) |v| result.colors.selection_bg = v;
        if (file.colors.selection_fg) |v| result.colors.selection_fg = v;

        // UI Colors
        if (file.colors.ui.tab_bar_bg) |v| result.colors.ui.tab_bar_bg = v;
        if (file.colors.ui.tab_active) |v| result.colors.ui.tab_active = v;
        if (file.colors.ui.tab_inactive) |v| result.colors.ui.tab_inactive = v;
        if (file.colors.ui.pane_border) |v| result.colors.ui.pane_border = v;
        if (file.colors.ui.status_bar_bg) |v| result.colors.ui.status_bar_bg = v;
        if (file.colors.ui.agent_alert) |v| result.colors.ui.agent_alert = v;

        // Keybindings: file overrides completely replace base
        if (file.keybindings.len > 0) result.keybindings = file.keybindings;

        return result;
    }

    /// Validate config values, clamping invalid ones to safe defaults.
    pub fn validate(self: *Config) void {
        // Font size: must be in reasonable range
        if (self.font.size <= 0.0 or self.font.size > max_font_size) {
            std.log.warn("Invalid font.size={d:.1}, resetting to default {d:.1}", .{ self.font.size, default_font_size });
            self.font.size = default_font_size;
        } else if (self.font.size < min_font_size) {
            std.log.warn("font.size={d:.1} too small, clamping to {d:.1}", .{ self.font.size, min_font_size });
            self.font.size = min_font_size;
        }

        // Cols: must be reasonable
        if (self.window.cols < min_cols or self.window.cols > max_cols) {
            std.log.warn("Invalid window.cols={}, resetting to default {}", .{ self.window.cols, default_cols });
            self.window.cols = default_cols;
        }

        // Rows: must be reasonable
        if (self.window.rows < min_rows or self.window.rows > max_rows) {
            std.log.warn("Invalid window.rows={}, resetting to default {}", .{ self.window.rows, default_rows });
            self.window.rows = default_rows;
        }

        // Opacity: clamp to 0.0-1.0
        if (self.window.opacity < 0.0 or self.window.opacity > 1.0) {
            std.log.warn("Invalid window.opacity={d:.2}, clamping to 0.0-1.0", .{self.window.opacity});
            self.window.opacity = std.math.clamp(self.window.opacity, 0.0, 1.0);
        }

        // Scrollback: must be positive
        if (self.scrollback.lines < 0) {
            std.log.warn("Invalid scrollback.lines={}, resetting to default {}", .{ self.scrollback.lines, default_scrollback });
            self.scrollback.lines = default_scrollback;
        }
    }

    // ------------------------------------------------------------------
    // Backward-compatible accessors for existing code (App.zig, Surface.zig)
    // that used flat field names from the old Config struct.
    // ------------------------------------------------------------------

    /// Returns font family (nullable).
    pub fn font_family(self: Config) ?[]const u8 {
        return self.font.family;
    }

    /// Returns font size in points.
    pub fn font_size_pt(self: Config) f32 {
        return self.font.size;
    }

    /// Returns column count as u16.
    pub fn cols(self: Config) u16 {
        return @intCast(@min(self.window.cols, std.math.maxInt(u16)));
    }

    /// Returns row count as u16.
    pub fn rows(self: Config) u16 {
        return @intCast(@min(self.window.rows, std.math.maxInt(u16)));
    }

    /// Returns grid padding.
    pub fn grid_padding(self: Config) f32 {
        return self.window.padding;
    }

    /// Returns scrollback lines as u32.
    pub fn scrollback_lines(self: Config) u32 {
        return @intCast(@min(self.scrollback.lines, std.math.maxInt(u32)));
    }

    /// Returns window title. String literals are sentinel-terminated;
    /// dynamically loaded titles from TOML may not be.
    pub fn window_title_str(self: Config) []const u8 {
        return self.window.title;
    }
};

/// Parse a hex color string like "#FF5555" or "#ff5555" into [3]u8 RGB.
pub fn parseHexColor(hex: []const u8) ![3]u8 {
    if (hex.len < 7 or hex[0] != '#') return error.InvalidColorFormat;
    const r = std.fmt.parseInt(u8, hex[1..3], 16) catch return error.InvalidColorFormat;
    const g = std.fmt.parseInt(u8, hex[3..5], 16) catch return error.InvalidColorFormat;
    const b = std.fmt.parseInt(u8, hex[5..7], 16) catch return error.InvalidColorFormat;
    return .{ r, g, b };
}
