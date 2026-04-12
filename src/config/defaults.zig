/// Cross-platform config path detection and --dump-config formatting.
///
/// Default config paths (D-11: cross-platform consistency):
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
    // D-11: All platforms use ~/.config/pterm/config.toml
    // This non-allocator version cannot construct dynamic paths,
    // so it returns null. Callers should use defaultConfigPathAlloc().
    return null;
}

/// Return the default config path using an allocator for dynamic path construction.
/// D-11: All platforms use ~/.config/pterm/config.toml for cross-platform consistency.
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
/// This implements --dump-config (D-04).
pub fn dumpConfig() void {
    const output =
        \\# PTerm Configuration
        \\# Default values shown. Uncomment and modify to customize.
        \\
        \\# Import other config files (resolved relative to this file)
        \\# import = ["base.toml"]
        \\
        \\[font]
        \\# family = ""        # empty = platform default
        \\size = 13.0
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
        \\# working_dir = ""   # empty = inherit
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
        \\[search]
        \\# Empty for v1 (plain text search only)
        \\
        \\[url]
        \\enabled = true
        \\
        \\[bell]
        \\mode = "visual"     # visual, sound, both, none
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
