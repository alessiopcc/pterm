const std = @import("std");
const App = @import("app").App;
const config_mod = @import("config");
const Config = config_mod.Config;
const cli_mod = @import("cli");
const defaults_mod = @import("defaults");
const keybinding_tui = @import("keybinding_tui");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Arena for CLI args and config strings — freed at process exit
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Parse CLI args (string values duped into arena)
    const cli_args = try cli_mod.parse(arena_alloc);

    // Handle --dump-config (D-04)
    if (cli_args.dump_config) {
        defaults_mod.dumpConfig();
        return;
    }

    // Handle --check-config (D-05)
    if (cli_args.check_config) {
        const config = Config.load(arena_alloc, cli_args) catch |err| {
            std.log.err("Config error: {}", .{err});
            std.process.exit(1);
        };
        _ = config;
        std.log.info("Config OK", .{});
        return;
    }

    // Handle --set-keybindings: launch interactive TUI and exit (D-22)
    if (cli_args.set_keybindings) {
        const config_path = cli_args.config_path orelse (defaults_mod.defaultConfigPathAlloc(arena_alloc) catch null) orelse {
            std.log.err("Cannot determine config path. Use --config <path>.", .{});
            std.process.exit(1);
        };
        try keybinding_tui.run(allocator, config_path, null);
        return;
    }

    // Resolve config path and log it
    const resolved_config_path = cli_args.config_path orelse (defaults_mod.defaultConfigPathAlloc(arena_alloc) catch null);
    if (resolved_config_path) |p| {
        std.log.info("Config: {s}", .{p});
    }

    // Load full config pipeline: defaults -> TOML file -> env vars -> CLI flags
    const config = try Config.load(arena_alloc, cli_args);

    var app = try App.init(allocator, config, .{
        .perf_logging = cli_args.perf_logging,
        .debug_keys = cli_args.debug_keys,
    });
    defer app.deinit();

    // Set config path for hot-reload watcher
    const defaults_path = defaults_mod.defaultConfigPathAlloc(arena_alloc) catch null;
    app.config_path = cli_args.config_path orelse defaults_path;

    try app.start();
    try app.run();
}
