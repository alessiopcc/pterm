/// Platform-specific config path detection and --dump-config formatting.
///
/// Default config paths per platform (D-01):
///   Linux:   ~/.config/termp/config.toml (XDG_CONFIG_HOME)
///   macOS:   ~/Library/Application Support/termp/config.toml
///   Windows: %APPDATA%\termp\config.toml
const std = @import("std");
const builtin = @import("builtin");

/// Return the platform-appropriate default config file path, or null if undetermined.
/// The returned string is a static/comptime path or environment-derived.
pub fn defaultConfigPath() ?[]const u8 {
    return defaultConfigPathImpl();
}

fn defaultConfigPathImpl() ?[]const u8 {
    if (builtin.os.tag == .windows) {
        // %APPDATA%\termp\config.toml
        const appdata = std.process.getEnvVarOwned(std.heap.page_allocator, "APPDATA") catch return null;
        // Note: This leaks the appdata string, but it's called at most once at startup.
        // A proper implementation would use an allocator, but for the default path
        // detection this is acceptable.
        _ = appdata;
        // For now, return a well-known pattern. The actual path construction
        // needs an allocator which we don't want to require here.
        return null; // Caller should check APPDATA env var
    } else if (builtin.os.tag == .macos) {
        return null; // ~/Library/Application Support/termp/config.toml -- needs HOME
    } else {
        // Linux/other: XDG_CONFIG_HOME or ~/.config
        return null; // $XDG_CONFIG_HOME/termp/config.toml or ~/.config/termp/config.toml
    }
}

/// Return the default config path using an allocator for dynamic path construction.
pub fn defaultConfigPathAlloc(allocator: std.mem.Allocator) !?[]const u8 {
    if (builtin.os.tag == .windows) {
        const appdata = std.process.getEnvVarOwned(allocator, "APPDATA") catch return null;
        defer allocator.free(appdata);
        const path = try std.fmt.allocPrint(allocator, "{s}\\termp\\config.toml", .{appdata});
        return path;
    } else if (builtin.os.tag == .macos) {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
        defer allocator.free(home);
        const path = try std.fmt.allocPrint(allocator, "{s}/Library/Application Support/termp/config.toml", .{home});
        return path;
    } else {
        // Linux: XDG_CONFIG_HOME or ~/.config
        const config_home = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
            defer allocator.free(home);
            const path = try std.fmt.allocPrint(allocator, "{s}/.config/termp/config.toml", .{home});
            return path;
        };
        defer allocator.free(config_home);
        const path = try std.fmt.allocPrint(allocator, "{s}/termp/config.toml", .{config_home});
        return path;
    }
}

/// Print the full default configuration as commented TOML to stdout.
/// This implements --dump-config (D-04).
pub fn dumpConfig() void {
    const output =
        \\# TermP Configuration
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
        \\title = "TermP"
        \\cols = 160
        \\rows = 48
        \\padding = 4.0
        \\opacity = 1.0
        \\
        \\[cursor]
        \\style = "block"      # block, bar, underline
        \\blink = true
        \\
        \\[scrollback]
        \\lines = 10000
        \\
        \\[shell]
        \\# program = ""       # empty = auto-detect
        \\# working_dir = ""   # empty = inherit
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
        \\
    ;
    const stdout_file = std.fs.File.stdout();
    stdout_file.writeAll(output) catch {};
    stdout_file.writeAll("\n") catch {};
}
