const std = @import("std");
const pio = @import("pio");
const builtin = @import("builtin");
const build_options = @import("build_options");
const App = @import("app").App;
const config_mod = @import("config");
const Config = config_mod.Config;
const cli_mod = @import("cli");
const defaults_mod = @import("defaults");
const keybinding_tui = @import("keybinding_tui");
const crash = @import("crash");

pub const panic = std.debug.FullPanic(crash.panicHandler);

// Disable stdlib's vectored segfault handler so our SEH unhandled-exception
// filter sees the original ACCESS_VIOLATION (otherwise stdlib catches it first
// and traps, leaving us with a useless BREAKPOINT exception code).
pub const std_options: std.Options = .{ .enable_segfault_handler = false };

pub fn main(init: std.process.Init) !void {
    pio.init(init);
    crash.install();

    const allocator = init.gpa;
    const io = init.io;

    // Arena for CLI args and config strings — freed at process exit
    const arena_alloc = init.arena.allocator();

    // Print-only flags need the terminal pterm was started from.
    if (builtin.os.tag == .windows and try printsOnly(arena_alloc, init.minimal.args)) {
        attachParentConsole();
    }

    // Parse CLI args (string values duped into arena)
    const cli_args = try cli_mod.parse(arena_alloc, init.minimal.args);

    // Handle --version
    if (cli_args.version) {
        const version_msg = "pterm " ++ build_options.version ++ "\n";
        std.Io.File.stdout().writeStreamingAll(io, version_msg) catch |err| {
            std.log.err("Failed to write version: {}", .{err});
            std.process.exit(1);
        };
        std.process.exit(0);
    }

    // Handle --init-config
    if (cli_args.init_config) {
        const default_config = @embedFile("config/default_config.toml");
        const home = pio.getEnvVarOwned(arena_alloc, if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") catch {
            std.log.err("Cannot determine home directory", .{});
            std.process.exit(1);
        };
        const config_dir = std.fmt.allocPrint(arena_alloc, "{s}/.config/pterm", .{home}) catch {
            std.log.err("Out of memory", .{});
            std.process.exit(1);
        };
        std.Io.Dir.cwd().createDirPath(io, config_dir) catch |err| {
            std.log.err("Error creating config directory: {}", .{err});
            std.process.exit(1);
        };
        const config_path = std.fmt.allocPrint(arena_alloc, "{s}/config.toml", .{config_dir}) catch {
            std.log.err("Out of memory", .{});
            std.process.exit(1);
        };
        const file = std.Io.Dir.cwd().createFile(io, config_path, .{ .exclusive = true }) catch |err| {
            if (err == error.PathAlreadyExists) {
                std.log.err("Config already exists: {s}", .{config_path});
                std.process.exit(1);
            }
            std.log.err("Error creating config: {}", .{err});
            std.process.exit(1);
        };
        defer file.close(io);
        file.writeStreamingAll(io, default_config) catch |err| {
            std.log.err("Error writing config: {}", .{err});
            std.process.exit(1);
        };
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Created: {s}\n", .{config_path}) catch "Created config\n";
        std.Io.File.stdout().writeStreamingAll(io, msg) catch {};
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

    // Handle --list-keybindings: print the bindings from the loaded config
    if (cli_args.list_keybindings) {
        const config = Config.load(arena_alloc, cli_args) catch |err| {
            std.log.err("Config error: {}", .{err});
            std.process.exit(1);
        };
        const user_bindings: ?[]const keybinding_tui.UserBinding = if (config.keybindings.len > 0)
            @ptrCast(config.keybindings)
        else
            null;
        var out: std.Io.Writer.Allocating = .init(arena_alloc);
        try keybinding_tui.writeList(arena_alloc, user_bindings, &out.writer);
        std.Io.File.stdout().writeStreamingAll(io, out.written()) catch |err| {
            std.log.err("Failed to write keybindings: {}", .{err});
            std.process.exit(1);
        };
        std.process.exit(0);
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
        .version = build_options.version,
    });
    defer app.deinit();

    // Set config path for hot-reload watcher
    const defaults_path = defaults_mod.defaultConfigPathAlloc(arena_alloc) catch null;
    app.config_path = cli_args.config_path orelse defaults_path;

    try app.start();
    try app.run();
}

/// Flags that print and exit without opening a window.
const print_only_flags = [_][]const u8{
    "--help", "-h", "--version", "--list-keybindings", "--dump-config", "--check-config", "--init-config",
};

fn printsOnly(arena: std.mem.Allocator, process_args: std.process.Args) !bool {
    var args = try process_args.iterateAllocator(arena);
    defer args.deinit();
    _ = args.next(); // exe name
    while (args.next()) |arg| {
        for (print_only_flags) |flag| {
            if (std.mem.eql(u8, arg, flag)) return true;
        }
    }
    return false;
}

const win = struct {
    const HANDLE = std.os.windows.HANDLE;
    const ATTACH_PARENT_PROCESS: u32 = 0xFFFF_FFFF;
    const STD_OUTPUT_HANDLE: u32 = 0xFFFF_FFF5; // (DWORD)-11
    const STD_ERROR_HANDLE: u32 = 0xFFFF_FFF4; // (DWORD)-12
    const GENERIC_READ_WRITE: u32 = 0xC000_0000;
    const FILE_SHARE_READ_WRITE: u32 = 0x3;
    const OPEN_EXISTING: u32 = 3;

    extern "kernel32" fn AttachConsole(process_id: u32) callconv(.winapi) i32;
    extern "kernel32" fn SetStdHandle(std_handle: u32, handle: HANDLE) callconv(.winapi) i32;
    extern "kernel32" fn CreateFileW(
        name: [*:0]const u16,
        access: u32,
        share: u32,
        security: ?*anyopaque,
        disposition: u32,
        flags: u32,
        template: ?HANDLE,
    ) callconv(.winapi) HANDLE;
};

/// The Windows build is a GUI program, so a terminal that starts it doesn't
/// give it stdout or stderr, and anything printed is lost. Attach to the
/// parent's console and point the missing handles at it. Handles that are
/// already set (output piped or redirected) are kept.
fn attachParentConsole() void {
    const params = std.os.windows.peb().ProcessParameters;
    const need_out = !hasHandle(&params.hStdOutput);
    const need_err = !hasHandle(&params.hStdError);
    if (!need_out and !need_err) return;
    if (win.AttachConsole(win.ATTACH_PARENT_PROCESS) == 0) return;
    const conout = win.CreateFileW(
        std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$"),
        win.GENERIC_READ_WRITE,
        win.FILE_SHARE_READ_WRITE,
        null,
        win.OPEN_EXISTING,
        0,
        null,
    );
    if (conout == std.os.windows.INVALID_HANDLE_VALUE) return;
    if (need_out) _ = win.SetStdHandle(win.STD_OUTPUT_HANDLE, conout);
    if (need_err) _ = win.SetStdHandle(win.STD_ERROR_HANDLE, conout);
}

/// The std handle fields are typed non-null, but a GUI process gets 0 there.
/// Read the raw value so the check isn't optimized away.
fn hasHandle(field: *const std.os.windows.HANDLE) bool {
    const raw = @as(*const volatile usize, @ptrCast(field)).*;
    return raw != 0 and raw != @intFromPtr(std.os.windows.INVALID_HANDLE_VALUE);
}
