/// PTERM_* environment variable override application.
///
/// Naming convention: PTERM_{SECTION}_{FIELD} in uppercase.
/// Env vars override config file values but not CLI flags (tier 3 of 4).
const std = @import("std");
const Config = @import("Config.zig").Config;

/// Apply PTERM_* environment variable overrides to config.
/// Uses a temporary allocator for env var lookups. Returned Config
/// references env var string memory that lives for the process lifetime.
pub fn applyOverrides(config: Config) Config {
    var result = config;

    if (getEnvFloat("PTERM_FONT_SIZE")) |s| result.font.size = s;
    // Note: PTERM_WINDOW_TITLE requires allocated memory; skip for now
    // as env var strings have process lifetime but we'd need to allocate for []const u8.
    if (getEnvI64("PTERM_WINDOW_COLS")) |c| result.window.cols = c;
    if (getEnvI64("PTERM_WINDOW_ROWS")) |r| result.window.rows = r;
    if (getEnvI64("PTERM_SCROLLBACK_LINES")) |l| result.scrollback.lines = l;
    if (getEnvFloat("PTERM_WINDOW_OPACITY")) |o| result.window.opacity = o;

    return result;
}

fn getEnvFloat(name: []const u8) ?f32 {
    // Use page_allocator for env var lookup (small, infrequent)
    const val = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return null;
    defer std.heap.page_allocator.free(val);
    return std.fmt.parseFloat(f32, val) catch null;
}

fn getEnvI64(name: []const u8) ?i64 {
    const val = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return null;
    defer std.heap.page_allocator.free(val);
    return std.fmt.parseInt(i64, val, 10) catch null;
}
