/// Configuration system for PTerm.
///
/// Provides a four-tier config loading pipeline:
///   1. Built-in defaults (zero-friction first launch)
///   2. TOML config file (with import/merge support)
///   3. PTERM_* environment variable overrides
///   4. CLI flag overrides (highest priority)
///
/// After loading, validate() clamps invalid values to safe defaults.
const std = @import("std");
const loader = @import("loader");
const defaults_mod = @import("defaults");
const cli_mod = @import("cli");
const env_mod = @import("env");
const layout_mod = @import("layout");
const LayoutPreset = layout_mod.LayoutPreset;

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
    // [search]
    search: Search = .{},
    // [url]
    url: Url = .{},
    // [bell]
    bell: Bell = .{},
    // [agent]
    agent: Agent = .{},
    // [status_bar]
    status_bar: StatusBar = .{},
    // theme = "..." top-level key
    theme: ?[]const u8 = null,
    // [keybindings] — raw action=combo pairs from TOML, passed to buildMap at runtime
    keybindings: []const KeybindingEntry = &.{},
    // [layout.*] — named layout presets parsed from TOML
    layouts: []LayoutPreset.LayoutPreset = &.{},
    /// Arena that owns all heap allocations for this Config instance.
    /// null for defaults()-created configs (no heap allocations).
    config_arena: ?*std.heap.ArenaAllocator = null,

    /// Agent monitoring config.
    /// Controls pattern-based detection and optional idle detection.
    pub const Agent = struct {
        /// Whether agent monitoring is active. enabled by default.
        enabled: bool = true,
        /// Pattern preset name: "conservative" or "broad". conservative default.
        preset: []const u8 = "conservative",
        /// Whether idle detection is enabled. off by default.
        idle_detection: bool = false,
        /// Idle timeout in seconds. 5 seconds default.
        idle_timeout: i64 = 5,
        /// Number of terminal lines to scan from the end. 3 lines default.
        scan_lines: i64 = 3,
        /// Custom regex/literal patterns appended to preset patterns..
        custom_patterns: ?[]const []const u8 = null,

        // Notification fields
        /// Whether OS desktop notifications are enabled. enabled by default.
        notifications: bool = true,
        /// Whether to include sound in notification. enabled by default.
        notification_sound: bool = true,
        /// Per-pane cooldown in seconds between notifications. 30s default.
        notification_cooldown: i64 = 30,
        /// Whether to suppress notification when PTerm window is focused. true by default.
        suppress_when_focused: bool = true,
    };

    /// Status bar config.
    /// Controls the persistent status bar at the bottom of the window.
    pub const StatusBar = struct {
        /// Whether the status bar is visible. visible by default.
        visible: bool = true,
    };

    /// Search config (empty stub for v1, no regex, no history).
    pub const Search = struct {};

    /// URL detection config (enabled by default).
    pub const Url = struct {
        enabled: bool = true,
    };

    /// Bell notification config (visual mode default).
    pub const Bell = struct {
        mode: BellMode = .visual,

        pub const BellMode = enum { visual, sound, both, none };
    };

    pub const KeybindingEntry = struct {
        action_name: []const u8,
        combo_str: []const u8,
    };

    pub const Font = struct {
        family: ?[]const u8 = null, // null = platform default
        size: f32 = 11.0,
        fallback: ?[]const []const u8 = null, // Additional fallback fonts
    };

    pub const Window = struct {
        title: []const u8 = "PTerm",
        cols: i64 = 200,
        rows: i64 = 55,
        padding: f32 = 4.0,
        opacity: f32 = 1.0,
    };

    pub const Cursor = struct {
        style: CursorStyle = .block,
        blink: bool = false,
    };

    pub const CursorStyle = enum { block, hollow, bar, underline };

    pub const Scrollback = struct {
        lines: i64 = 10_000,
    };

    pub const Shell = struct {
        program: ?[]const u8 = null, // null = auto-detect
        working_dir: ?[]const u8 = "~",
        args: ?[]const []const u8 = null, // raw args appended after shell binary
    };

    pub const Colors = struct {
        foreground: ?[]const u8 = null,
        background: ?[]const u8 = null,
        cursor_color: ?[]const u8 = null,
        cursor_text: ?[]const u8 = null,
        selection_bg: ?[]const u8 = null,
        selection_fg: ?[]const u8 = null,
        ui: UiColors = .{},
        normal: AnsiNormal = .{},
        bright: AnsiBright = .{},
    };

    /// Per Named ANSI color overrides for colors 0-7.
    /// Each field is optional; null means use active theme default.
    pub const AnsiNormal = struct {
        black: ?[]const u8 = null,
        red: ?[]const u8 = null,
        green: ?[]const u8 = null,
        yellow: ?[]const u8 = null,
        blue: ?[]const u8 = null,
        magenta: ?[]const u8 = null,
        cyan: ?[]const u8 = null,
        white: ?[]const u8 = null,
    };

    /// Per Named ANSI color overrides for bright colors 8-15.
    /// Each field is optional; null means use active theme default.
    pub const AnsiBright = struct {
        black: ?[]const u8 = null,
        red: ?[]const u8 = null,
        green: ?[]const u8 = null,
        yellow: ?[]const u8 = null,
        blue: ?[]const u8 = null,
        magenta: ?[]const u8 = null,
        cyan: ?[]const u8 = null,
        white: ?[]const u8 = null,
    };

    /// Per UI chrome colors for tab bar, panes, status bar, agent alerts.
    /// Fields are schema stubs with sensible Catppuccin Mocha defaults.
    /// MUST be present in schema now so config files and themes can define them.
    pub const UiColors = struct {
        tab_bar_bg: ?[]const u8 = null,
        tab_active: ?[]const u8 = null,
        tab_inactive: ?[]const u8 = null,
        pane_border: ?[]const u8 = null,
        pane_border_active: ?[]const u8 = null,
        status_bar_bg: ?[]const u8 = null,
        agent_alert: ?[]const u8 = null,
        // Search, URL, bell UI colors
        search_bar_bg: ?[]const u8 = null,
        search_match: ?[]const u8 = null,
        search_current_match: ?[]const u8 = null,
        url_hover: ?[]const u8 = null,
        bell_flash: ?[]const u8 = null,
        bell_badge: ?[]const u8 = null,
    };

    /// Default config path constants.
    pub const default_font_size: f32 = 11.0;
    pub const default_cols: i64 = 200;
    pub const default_rows: i64 = 55;
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

    /// Free all heap allocations owned by this Config by destroying its arena.
    /// Safe to call on defaults()-created configs (arena is null → no-op).
    pub fn deinit(self: *const Config) void {
        if (self.config_arena) |arena| {
            const backing = arena.child_allocator;
            arena.deinit();
            backing.destroy(arena);
        }
    }

    /// Full four-tier loading pipeline.
    /// 1. defaults() -> 2. TOML file -> 3. env overrides -> 4. CLI overrides -> validate()
    /// All heap allocations go through a per-Config arena so deinit() frees everything.
    pub fn load(allocator: std.mem.Allocator, cli_args: cli_mod.CliArgs) !Config {
        // Create a per-Config arena for all string allocations
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        const arena_alloc = arena.allocator();

        var config = Config.defaults();
        config.config_arena = arena;

        // Tier 2: Load TOML config file (if exists)
        const config_path = cli_args.config_path orelse (defaults_mod.defaultConfigPathAlloc(arena_alloc) catch null);
        if (config_path) |path| {
            if (loader.loadConfigFromPath(arena_alloc, path)) |file_config| {
                config = mergeFileIntoConfig(config, file_config);
                config.config_arena = arena; // preserve arena after merge overwrites
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
        config.config_arena = arena; // preserve arena after overrides

        // Tier 4: CLI flag overrides
        config = cli_mod.applyOverrides(config, cli_args);
        config.config_arena = arena; // preserve arena after overrides

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
        if (file.font.fallback) |v| result.font.fallback = v;

        // Window
        if (!std.mem.eql(u8, file.window.title, "PTerm")) result.window.title = file.window.title;
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
        if (file.shell.args) |v| result.shell.args = v;

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
        if (file.colors.ui.pane_border_active) |v| result.colors.ui.pane_border_active = v;
        if (file.colors.ui.status_bar_bg) |v| result.colors.ui.status_bar_bg = v;
        if (file.colors.ui.agent_alert) |v| result.colors.ui.agent_alert = v;
        if (file.colors.ui.search_bar_bg) |v| result.colors.ui.search_bar_bg = v;
        if (file.colors.ui.search_match) |v| result.colors.ui.search_match = v;
        if (file.colors.ui.search_current_match) |v| result.colors.ui.search_current_match = v;
        if (file.colors.ui.url_hover) |v| result.colors.ui.url_hover = v;
        if (file.colors.ui.bell_flash) |v| result.colors.ui.bell_flash = v;
        if (file.colors.ui.bell_badge) |v| result.colors.ui.bell_badge = v;

        // Bell
        if (file.bell.mode != .visual) result.bell.mode = file.bell.mode;

        // URL
        if (!file.url.enabled) result.url.enabled = file.url.enabled;

        // Agent
        if (!file.agent.enabled) result.agent.enabled = file.agent.enabled;
        if (!std.mem.eql(u8, file.agent.preset, "conservative")) result.agent.preset = file.agent.preset;
        if (file.agent.idle_detection) result.agent.idle_detection = file.agent.idle_detection;
        if (file.agent.idle_timeout != 5) result.agent.idle_timeout = file.agent.idle_timeout;
        if (file.agent.scan_lines != 3) result.agent.scan_lines = file.agent.scan_lines;
        if (file.agent.custom_patterns) |v| result.agent.custom_patterns = v;

        // Agent notification fields
        if (!file.agent.notifications) result.agent.notifications = file.agent.notifications;
        if (!file.agent.notification_sound) result.agent.notification_sound = file.agent.notification_sound;
        if (file.agent.notification_cooldown != 30) result.agent.notification_cooldown = file.agent.notification_cooldown;
        if (!file.agent.suppress_when_focused) result.agent.suppress_when_focused = file.agent.suppress_when_focused;

        // Status bar
        if (!file.status_bar.visible) result.status_bar.visible = file.status_bar.visible;

        // Theme
        if (file.theme) |v| result.theme = v;

        // ANSI normal colors
        if (file.colors.normal.black) |v| result.colors.normal.black = v;
        if (file.colors.normal.red) |v| result.colors.normal.red = v;
        if (file.colors.normal.green) |v| result.colors.normal.green = v;
        if (file.colors.normal.yellow) |v| result.colors.normal.yellow = v;
        if (file.colors.normal.blue) |v| result.colors.normal.blue = v;
        if (file.colors.normal.magenta) |v| result.colors.normal.magenta = v;
        if (file.colors.normal.cyan) |v| result.colors.normal.cyan = v;
        if (file.colors.normal.white) |v| result.colors.normal.white = v;

        // ANSI bright colors
        if (file.colors.bright.black) |v| result.colors.bright.black = v;
        if (file.colors.bright.red) |v| result.colors.bright.red = v;
        if (file.colors.bright.green) |v| result.colors.bright.green = v;
        if (file.colors.bright.yellow) |v| result.colors.bright.yellow = v;
        if (file.colors.bright.blue) |v| result.colors.bright.blue = v;
        if (file.colors.bright.magenta) |v| result.colors.bright.magenta = v;
        if (file.colors.bright.cyan) |v| result.colors.bright.cyan = v;
        if (file.colors.bright.white) |v| result.colors.bright.white = v;

        // Keybindings: file overrides completely replace base
        if (file.keybindings.len > 0) result.keybindings = file.keybindings;

        // Layouts: file overrides completely replace base
        if (file.layouts.len > 0) result.layouts = file.layouts;

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

        // Agent: scan_lines clamped to [1, 20]
        if (self.agent.scan_lines < 1 or self.agent.scan_lines > 20) {
            std.log.warn("Invalid agent.scan_lines={}, clamping to [1, 20]", .{self.agent.scan_lines});
            self.agent.scan_lines = std.math.clamp(self.agent.scan_lines, 1, 20);
        }

        // Agent: idle_timeout clamped to [1, 300]
        if (self.agent.idle_timeout < 1 or self.agent.idle_timeout > 300) {
            std.log.warn("Invalid agent.idle_timeout={}, clamping to [1, 300]", .{self.agent.idle_timeout});
            self.agent.idle_timeout = std.math.clamp(self.agent.idle_timeout, 1, 300);
        }

        // Agent: notification_cooldown clamped to [1, 600]
        if (self.agent.notification_cooldown < 1 or self.agent.notification_cooldown > 600) {
            std.log.warn("Invalid agent.notification_cooldown={}, clamping to [1, 600]", .{self.agent.notification_cooldown});
            self.agent.notification_cooldown = std.math.clamp(self.agent.notification_cooldown, 1, 600);
        }

        // Agent: preset must be "conservative" or "broad"
        if (!std.mem.eql(u8, self.agent.preset, "conservative") and !std.mem.eql(u8, self.agent.preset, "broad")) {
            std.log.warn("Invalid agent.preset='{s}', resetting to 'conservative'", .{self.agent.preset});
            self.agent.preset = "conservative";
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

    /// Returns font fallback list (nullable).
    pub fn font_fallback(self: Config) ?[]const []const u8 {
        return self.font.fallback;
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
