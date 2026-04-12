/// Windows font discovery using directory scanning (D-11).
///
/// Scans standard Windows font directories for known monospace font files.
/// A simple but reliable approach for v1. DirectWrite enumeration can be
/// added later for full font collection support.
const std = @import("std");
const DiscoverResult = @import("discovery.zig").DiscoverResult;

/// Known monospace font filenames mapped to their family names.
const KnownFont = struct {
    family: []const u8,
    filename: []const u8,
};

const known_monospace_fonts = [_]KnownFont{
    .{ .family = "JetBrains Mono", .filename = "JetBrainsMono-Regular.ttf" },
    .{ .family = "JetBrains Mono NL", .filename = "JetBrainsMonoNL-Regular.ttf" },
    .{ .family = "Cascadia Code", .filename = "CascadiaCode.ttf" },
    .{ .family = "Cascadia Mono", .filename = "CascadiaMono.ttf" },
    .{ .family = "Consolas", .filename = "consola.ttf" },
    .{ .family = "Courier New", .filename = "cour.ttf" },
    .{ .family = "Lucida Console", .filename = "lucon.ttf" },
    .{ .family = "DejaVu Sans Mono", .filename = "DejaVuSansMono.ttf" },
    .{ .family = "Fira Code", .filename = "FiraCode-Regular.ttf" },
};

/// System font directories to search.
const system_font_dir = "C:\\Windows\\Fonts\\";

/// Discover a font file path by family name (case-insensitive match).
/// Returns null if no matching font is found.
pub fn discover(allocator: std.mem.Allocator, family: []const u8) ?DiscoverResult {
    // Check known fonts first (fast path).
    for (known_monospace_fonts) |known| {
        if (eqlIgnoreCase(family, known.family)) {
            return checkFontFile(allocator, known.filename);
        }
    }

    // Try direct filename match in font directory.
    // Build a filename guess: "{family}.ttf"
    const filename = std.fmt.allocPrint(allocator, "{s}.ttf", .{family}) catch return null;
    defer allocator.free(filename);

    if (checkFontFile(allocator, filename)) |result| return result;

    return null;
}

/// Discover the first available system monospace font.
pub fn discoverDefaultMonospace(allocator: std.mem.Allocator) ?DiscoverResult {
    // Try known fonts in preference order.
    for (known_monospace_fonts) |known| {
        if (checkFontFile(allocator, known.filename)) |result| return result;
    }
    return null;
}

fn checkFontFile(allocator: std.mem.Allocator, filename: []const u8) ?DiscoverResult {
    // Check system font directory.
    const full_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ system_font_dir, filename }) catch return null;

    // Verify file exists.
    const file = std.fs.openFileAbsolute(full_path, .{}) catch {
        allocator.free(full_path);
        // Also check user font directory.
        return checkUserFontFile(allocator, filename);
    };
    file.close();

    return DiscoverResult{
        .path = full_path,
        .index = 0,
    };
}

fn checkUserFontFile(allocator: std.mem.Allocator, filename: []const u8) ?DiscoverResult {
    // Get %LOCALAPPDATA%\Microsoft\Windows\Fonts\
    const local_app_data = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch return null;
    defer allocator.free(local_app_data);

    const user_path = std.fmt.allocPrint(
        allocator,
        "{s}\\Microsoft\\Windows\\Fonts\\{s}",
        .{ local_app_data, filename },
    ) catch return null;

    const file = std.fs.openFileAbsolute(user_path, .{}) catch {
        allocator.free(user_path);
        return null;
    };
    file.close();

    return DiscoverResult{
        .path = user_path,
        .index = 0,
    };
}

/// Discover the Segoe UI Emoji font (Windows default color emoji font).
pub fn discoverEmojiFont(allocator: std.mem.Allocator) ?DiscoverResult {
    return checkFontFile(allocator, "seguiemj.ttf");
}

/// Discover a CJK-capable font (for Chinese, Japanese, Korean characters).
pub fn discoverCJKFont(allocator: std.mem.Allocator) ?DiscoverResult {
    // Try common CJK fonts in order of preference.
    const cjk_fonts = [_][]const u8{
        "YuGothM.ttc", // Yu Gothic Medium (Windows 10+)
        "YuGothR.ttc", // Yu Gothic Regular
        "msgothic.ttc", // MS Gothic
        "msmincho.ttc", // MS Mincho
        "meiryo.ttc", // Meiryo
        "malgun.ttf", // Malgun Gothic (Korean)
        "simsun.ttc", // SimSun (Chinese Simplified)
        "mingliu.ttc", // MingLiU (Chinese Traditional)
    };
    for (cjk_fonts) |filename| {
        if (checkFontFile(allocator, filename)) |result| return result;
    }
    return null;
}

/// Discover a Nerd Font symbols-only font (D-01).
/// Scans system and user font directories for known Nerd Font filenames.
pub fn discoverNerdFont(allocator: std.mem.Allocator) ?DiscoverResult {
    const nerd_fonts = [_][]const u8{
        // Standalone Nerd Font symbol packages (prefer system-installed over bundled)
        "SymbolsNerdFontMono-Regular.ttf",
        "SymbolsNerdFont-Regular.ttf",
    };
    for (nerd_fonts) |filename| {
        if (checkFontFile(allocator, filename)) |result| return result;
    }
    return null;
}

/// Discover a general Unicode symbol font (Dingbats, geometric shapes, etc.).
/// Covers characters like U+276F (❯) that coding fonts often lack.
pub fn discoverSymbolFont(allocator: std.mem.Allocator) ?DiscoverResult {
    const symbol_fonts = [_][]const u8{
        "seguisym.ttf", // Segoe UI Symbol (Windows 7+)
        "symbol.ttf", // Symbol
    };
    for (symbol_fonts) |filename| {
        if (checkFontFile(allocator, filename)) |result| return result;
    }
    return null;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}
