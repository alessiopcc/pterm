const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
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

    // Handle --version
    if (cli_args.version) {
        const version_msg = "pterm " ++ build_options.version ++ "\n";
        const stdout_file = std.fs.File.stdout();
        stdout_file.writeAll(version_msg) catch |err| {
            std.log.err("Failed to write version: {}", .{err});
            std.process.exit(1);
        };
        std.process.exit(0);
    }

    // Handle --init-config
    if (cli_args.init_config) {
        const default_config = @embedFile("config/default_config.toml");
        const home = std.process.getEnvVarOwned(arena_alloc, if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") catch {
            std.log.err("Cannot determine home directory", .{});
            std.process.exit(1);
        };
        const config_dir = std.fmt.allocPrint(arena_alloc, "{s}/.config/pterm", .{home}) catch {
            std.log.err("Out of memory", .{});
            std.process.exit(1);
        };
        std.fs.cwd().makePath(config_dir) catch |err| {
            std.log.err("Error creating config directory: {}", .{err});
            std.process.exit(1);
        };
        const config_path = std.fmt.allocPrint(arena_alloc, "{s}/config.toml", .{config_dir}) catch {
            std.log.err("Out of memory", .{});
            std.process.exit(1);
        };
        const file = std.fs.cwd().createFile(config_path, .{ .exclusive = true }) catch |err| {
            if (err == error.PathAlreadyExists) {
                std.log.err("Config already exists: {s}", .{config_path});
                std.process.exit(1);
            }
            std.log.err("Error creating config: {}", .{err});
            std.process.exit(1);
        };
        defer file.close();
        file.writeAll(default_config) catch |err| {
            std.log.err("Error writing config: {}", .{err});
            std.process.exit(1);
        };
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Created: {s}\n", .{config_path}) catch "Created config\n";
        const stdout = std.fs.File.stdout();
        stdout.writeAll(msg) catch {};
        std.process.exit(0);
    }

    // Handle --dump-config
    if (cli_args.dump_config) {
        defaults_mod.dumpConfig();
        return;
    }

    // Handle --check-config
    if (cli_args.check_config) {
        const config = Config.load(arena_alloc, cli_args) catch |err| {
            std.log.err("Config error: {}", .{err});
            std.process.exit(1);
        };
        _ = config;
        std.log.info("Config OK", .{});
        return;
    }

    // Handle --set-keybindings: launch interactive TUI and exit
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

    // GPU check: verify OpenGL 3.3 before creating the real window.
    // This provides a clear error message instead of cryptic GL failures.
    {
        const glfw = @import("zglfw");
        glfw.init() catch {
            std.log.err("Failed to initialize windowing system (GLFW). PTerm requires OpenGL 3.3 or later.", .{});
            std.process.exit(1);
        };

        // Set OpenGL 3.3 core profile hints
        glfw.windowHint(.context_version_major, 3);
        glfw.windowHint(.context_version_minor, 3);
        glfw.windowHint(.opengl_profile, .opengl_core_profile);
        glfw.windowHint(.visible, false); // hidden probe window

        const probe = glfw.createWindow(1, 1, "gpu-probe", null, null) catch {
            glfw.terminate();
            std.log.err("OpenGL 3.3 is not available on this system. PTerm requires a GPU with OpenGL 3.3 support.", .{});
            std.process.exit(1);
        };
        probe.destroy();
        glfw.terminate();
    }

    var app = try App.init(allocator, config, .{
        .perf_logging = cli_args.perf_logging,
        .debug_keys = cli_args.debug_keys,
        .layout_name = cli_args.layout,
    });
    defer app.deinit();

    // Set config path for hot-reload watcher
    const defaults_path = defaults_mod.defaultConfigPathAlloc(arena_alloc) catch null;
    app.config_path = cli_args.config_path orelse defaults_path;

    try app.start();
    try app.run();
}
