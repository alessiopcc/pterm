/// CLI argument parsing for TermP configuration.
///
/// Parses command-line flags: --config, --font-size, --title, --cols, --rows,
/// --working-dir, --dump-config, --check-config, --set-keybindings, --perf, --debug-keys.
/// CLI flags have highest priority in the four-tier config pipeline.
const std = @import("std");
const Config = @import("Config.zig").Config;

pub const CliArgs = struct {
    config_path: ?[]const u8 = null, // --config <path>
    font_size: ?f32 = null, // --font-size <float>
    title: ?[]const u8 = null, // --title <string>
    cols: ?i64 = null, // --cols <int>
    rows: ?i64 = null, // --rows <int>
    working_dir: ?[]const u8 = null, // --working-dir <path>
    dump_config: bool = false, // --dump-config
    check_config: bool = false, // --check-config
    set_keybindings: bool = false, // --set-keybindings (D-22)
    perf_logging: bool = false, // --perf
    debug_keys: bool = false, // --debug-keys
};

/// Parse CLI arguments from std.process args.
/// String values are duped into the allocator so they outlive the arg iterator.
pub fn parse(allocator: std.mem.Allocator) !CliArgs {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip exe name

    var result = CliArgs{};
    var wants_help = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            wants_help = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            if (args.next()) |v| result.config_path = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--font-size")) {
            if (args.next()) |v| {
                result.font_size = std.fmt.parseFloat(f32, v) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--title")) {
            if (args.next()) |v| result.title = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--cols")) {
            if (args.next()) |v| {
                result.cols = std.fmt.parseInt(i64, v, 10) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--rows")) {
            if (args.next()) |v| {
                result.rows = std.fmt.parseInt(i64, v, 10) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--working-dir")) {
            if (args.next()) |v| result.working_dir = try allocator.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--dump-config")) {
            result.dump_config = true;
        } else if (std.mem.eql(u8, arg, "--check-config")) {
            result.check_config = true;
        } else if (std.mem.eql(u8, arg, "--set-keybindings")) {
            result.set_keybindings = true;
        } else if (std.mem.eql(u8, arg, "--perf")) {
            result.perf_logging = true;
        } else if (std.mem.eql(u8, arg, "--debug-keys")) {
            result.debug_keys = true;
        }
    }
    if (wants_help) {
        printHelp(result.config_path, allocator);
        std.process.exit(0);
    }
    return result;
}

/// Alias for backward compatibility with Plan 02 code.
pub const parseArgs = parse;

fn printHelp(cli_config_path: ?[]const u8, allocator: std.mem.Allocator) void {
    const defaults_mod = @import("defaults");
    const resolved = cli_config_path orelse (defaults_mod.defaultConfigPathAlloc(allocator) catch null) orelse "(none)";

    std.debug.print(
        \\TermP - GPU-accelerated terminal emulator
        \\
        \\Usage: termp [options]
        \\
        \\Config: {s}
        \\
        \\Options:
        \\  --config <path>       Config file path
        \\  --font-size <float>   Override font size
        \\  --title <string>      Override window title
        \\  --cols <int>          Override column count
        \\  --rows <int>          Override row count
        \\  --working-dir <path>  Override working directory
        \\  --dump-config         Print default config to stdout
        \\  --check-config        Validate config and exit
        \\  --set-keybindings     Interactive keybinding configuration
        \\  --perf                Enable performance logging
        \\  --debug-keys          Log keystrokes to termp_debug.log
        \\  -h, --help            Show this help
        \\
    , .{resolved});
}

/// Apply CLI overrides to config. CLI has highest priority.
pub fn applyOverrides(config: Config, cli_args: CliArgs) Config {
    var result = config;
    if (cli_args.font_size) |s| result.font.size = s;
    if (cli_args.title) |t| result.window.title = t;
    if (cli_args.cols) |c| result.window.cols = c;
    if (cli_args.rows) |r| result.window.rows = r;
    if (cli_args.working_dir) |d| result.shell.working_dir = d;
    return result;
}
