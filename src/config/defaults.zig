/// Cross-platform config path detection and --dump-config formatting.
///
/// Default config paths:
///   All platforms: ~/.config/pterm/config.toml
///   Linux: Respects XDG_CONFIG_HOME if set
///   Windows: Uses %USERPROFILE%/.config/pterm/config.toml
const std = @import("std");
const builtin = @import("builtin");

/// Return the platform-appropriate default config file path, or null if undetermined.
/// The returned string is a static/comptime path or environment-derived.
pub fn defaultConfigPath() ?[]const u8 {
    return defaultConfigPathImpl();
}

fn defaultConfigPathImpl() ?[]const u8 {
    // All platforms use ~/.config/pterm/config.toml
    // This non-allocator version cannot construct dynamic paths,
    // so it returns null. Callers should use defaultConfigPathAlloc().
    return null;
}

/// Return the default config path using an allocator for dynamic path construction.
/// All platforms use ~/.config/pterm/config.toml for cross-platform consistency.
pub fn defaultConfigPathAlloc(allocator: std.mem.Allocator) !?[]const u8 {
    if (builtin.os.tag == .windows) {
        const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return null;
        defer allocator.free(home);
        return try std.fmt.allocPrint(allocator, "{s}/.config/pterm/config.toml", .{home});
    } else {
        // macOS + Linux: XDG_CONFIG_HOME or ~/.config
        const config_home = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
            defer allocator.free(home);
            return try std.fmt.allocPrint(allocator, "{s}/.config/pterm/config.toml", .{home});
        };
        defer allocator.free(config_home);
        return try std.fmt.allocPrint(allocator, "{s}/pterm/config.toml", .{config_home});
    }
}

/// Print the full default configuration as commented TOML to stdout.
/// This implements --dump-config.
pub fn dumpConfig() void {
    const output =
        \\# PTerm Configuration
        \\# Default values shown. Uncomment and modify to customize.
        \\
        \\# Import other config files (resolved relative to this file)
        \\# import = ["base.toml"]
        \\
        \\# Theme: select a built-in color theme as the base palette
        \\# theme = "default"  # default, dracula, solarized-dark, solarized-light, gruvbox-dark, nord, catppuccin-mocha, one-dark
        \\
        \\[font]
        \\# family = ""        # empty = platform default
        \\size = 11.0
        \\
        \\[window]
        \\title = "PTerm"
        \\cols = 160
        \\rows = 48
        \\padding = 4.0
        \\opacity = 1.0
        \\
        \\[cursor]
        \\style = "block"      # block, bar, underline
        \\blink = false
        \\
        \\[scrollback]
        \\lines = 10000
        \\
        \\[shell]
        \\# program = ""       # empty = auto-detect
        \\working_dir = "~"    # default = home dir; set path to override, "" = inherit CWD
        \\# args = []           # extra arguments, e.g. ["--login", "--norc"]
        \\
        \\[colors]
        \\# foreground = "#cdd6f4"
        \\# background = "#1e1e2e"
        \\# cursor_color = "#f5e0dc"
        \\# cursor_text = "#1e1e2e"
        \\# selection_bg = "#45475a"
        \\# selection_fg = "#cdd6f4"
        \\
        \\[colors.ui]
        \\# tab_bar_bg = "#181825"
        \\# tab_active = "#1e1e2e"
        \\# tab_inactive = "#313244"
        \\# pane_border = "#45475a"
        \\# pane_border_active = "#89B4FA"
        \\# status_bar_bg = "#181825"
        \\# agent_alert = "#f9e2af"
        \\# search_bar_bg = "#181825"
        \\# search_match = "#f9e2af"
        \\# search_current_match = "#f38ba8"
        \\# url_hover = "#89B4FA"
        \\# bell_flash = "#f9e2af"
        \\# bell_badge = "#f38ba8"
        \\
        \\[colors.normal]
        \\# Override individual ANSI colors (0-7). Unset colors use the active theme.
        \\# black = "#45475A"
        \\# red = "#F38BA8"
        \\# green = "#A6E3A1"
        \\# yellow = "#F9E2AF"
        \\# blue = "#89B4FA"
        \\# magenta = "#F5C2E7"
        \\# cyan = "#94E2D5"
        \\# white = "#BAC2DE"
        \\
        \\[colors.bright]
        \\# Override individual bright ANSI colors (8-15). Unset colors use the active theme.
        \\# black = "#585B70"
        \\# red = "#F38BA8"
        \\# green = "#A6E3A1"
        \\# yellow = "#F9E2AF"
        \\# blue = "#89B4FA"
        \\# magenta = "#F5C2E7"
        \\# cyan = "#94E2D5"
        \\# white = "#A6ADC8"
        \\
        \\[search]
        \\# Empty for v1 (plain text search only)
        \\
        \\[url]
        \\enabled = true
        \\
        \\[bell]
        \\mode = "visual"     # visual, sound, both, none
        \\
        \\[agent]
        \\# Agent monitoring and notification settings
        \\# enabled = true
        \\# preset = "conservative"  # conservative, broad
        \\# idle_detection = false
        \\# idle_timeout = 5
        \\# scan_lines = 3
        \\# custom_patterns = []  # additional prompt patterns to detect
        \\# notifications = true
        \\# notification_sound = true
        \\# notification_cooldown = 30
        \\# suppress_when_focused = true
        \\
        \\[status_bar]
        \\# Status bar visibility
        \\# visible = true
        \\
    ;
    const stdout_file = std.fs.File.stdout();
    stdout_file.writeAll(output) catch |err| {
        std.debug.print("Error writing config: {}\n", .{err});
        std.process.exit(1);
    };
    stdout_file.writeAll("\n") catch |err| {
        std.debug.print("Error writing config: {}\n", .{err});
        std.process.exit(1);
    };
}
