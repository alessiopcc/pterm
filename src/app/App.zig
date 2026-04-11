/// Application lifecycle: init, run, deinit.
///
/// Wires all subsystems together: Window, PTY, TermIO, Surface.
/// Owns the main event loop (D-15: main thread handles GLFW events only).
const std = @import("std");
const glfw = @import("zglfw");
const Config = @import("config").Config;
const Surface = @import("surface").Surface;
const termio_mod = @import("termio");
const pty_mod = @import("pty");
const shell_mod = @import("shell");
const window_mod = @import("window");
const fontgrid_mod = @import("fontgrid");
const font_types = @import("font_types");
const observer_mod = @import("observer");
const renderer_types = @import("renderer_types");
const watcher_mod = @import("watcher");
const FileWatcher = watcher_mod.FileWatcher;
const cli_mod = @import("cli");

const TermIO = termio_mod.TermIO;
const TermIOConfig = termio_mod.TermIOConfig;
const Pty = pty_mod.Pty;
const Window = window_mod.Window;

pub const AppOptions = struct {
    perf_logging: bool = false,
    debug_keys: bool = false,
};

// Static state for config reload callback (FileWatcher callback has no context pointer).
// Safe because there is exactly one App instance per process.
var g_reload_app: ?*App = null;

pub const App = struct {
    window: Window,
    surface: Surface,
    termio: TermIO,
    pty: Pty,
    allocator: std.mem.Allocator,
    config: Config,
    config_path: ?[]const u8,
    config_watcher: ?FileWatcher,

    pub fn init(allocator: std.mem.Allocator, config: Config, options: AppOptions) !App {
        // 2. Create TermIO
        var termio = try TermIO.init(allocator, TermIOConfig{
            .cols = config.cols(),
            .rows = config.rows(),
            .scrollback_lines = config.scrollback_lines(),
        });
        errdefer termio.deinit();

        // 3. Create PTY
        var pty = try Pty.init(allocator, .{
            .cols = config.cols(),
            .rows = config.rows(),
        });
        errdefer pty.deinit();

        // 4. Spawn shell process in PTY
        const shell_config = shell_mod.detectShell();
        try pty.spawn(shell_config.path, shell_config.args);

        // 5. Attach PTY to TermIO
        termio.attachPty(&pty);

        // 6. Create Window (GLFW init + window creation)
        // Need font metrics for cell size computation -- create a temporary FontGrid
        const dpi_scale: f32 = 1.0; // Will be updated after window creation
        const temp_font_config = font_types.FontConfig{
            .family = config.font_family(),
            .size_pt = config.font_size_pt(),
            .dpi_scale = dpi_scale,
        };
        var temp_font = try fontgrid_mod.FontGrid.init(allocator, temp_font_config);
        const metrics = temp_font.getMetrics();
        temp_font.deinit();

        var window = try Window.init(window_mod.WindowConfig{
            .cols = config.cols(),
            .rows = config.rows(),
            .cell_width = metrics.cell_width,
            .cell_height = metrics.cell_height,
            .grid_padding = config.grid_padding(),
            .title = "TermP", // TODO: support dynamic title from config
        });
        errdefer window.deinit();

        // 7. Create Surface (does NOT create OpenGLBackend -- render thread does that)
        const surface = try Surface.init(allocator, config, &window, &termio, .{
            .perf_logging = options.perf_logging,
            .debug_keys = options.debug_keys,
        });

        // NOTE: Do NOT set GLFW callbacks or start threads here.
        // The returned App struct will be moved to its final location (caller's stack).
        // Pointers to surface/window/termio taken here would become dangling.
        // Call app.start() after init returns to set up callbacks at stable addresses.

        return App{
            .window = window,
            .surface = surface,
            .termio = termio,
            .pty = pty,
            .allocator = allocator,
            .config = config,
            .config_path = null, // Set by caller before start()
            .config_watcher = null, // Initialized in start() if config_path is set
        };
    }

    /// Start all threads and wire GLFW callbacks.
    /// Must be called after init() returns and the App struct is at its final address.
    /// This is separate from init() because init() returns by value, which moves
    /// the struct — any pointers taken during init() would become dangling.
    pub fn start(self: *App) !void {
        // 1. Set GLFW callbacks, routing to Surface via user pointer.
        // Now &self.surface is stable because self is at its final location.
        self.window.setUserPointer(@ptrCast(&self.surface));
        self.window.setCallbacks(.{
            .key_callback = Surface.keyCallback,
            .char_callback = Surface.charCallback,
            .framebuffer_size_callback = Surface.framebufferSizeCallback,
            .focus_callback = Surface.focusCallback,
            .scroll_callback = Surface.scrollCallback,
        });

        // 2. Fix up internal pointers that were invalidated by the move.
        // Surface holds pointers to window and termio, which also moved.
        self.surface.window = &self.window;
        self.surface.termio = &self.termio;

        // 3. D-15: Detach GL context from main thread
        Window.detachContext();

        // 4. D-15: Start render thread (acquires GL context, creates OpenGLBackend)
        try self.surface.startRenderThread();

        // 5. Start TermIO (reader + parser threads)
        try self.termio.start();

        // 6. Set Observer.onScreenChange to request frame renders
        self.termio.terminal.observer.onScreenChange = makeScreenChangeCallback(&self.surface);

        // 7. D-14: Initialize config file watcher for hot-reload
        if (self.config_path) |path| {
            g_reload_app = self;
            self.config_watcher = FileWatcher.init(
                self.allocator,
                &.{path},
                configReloadCallback,
            ) catch null;
        }
    }

    /// Config reload callback — re-reads config and applies to surface.
    fn configReloadCallback() void {
        const self = g_reload_app orelse return;
        const cli_args = cli_mod.CliArgs{ .config_path = self.config_path };
        const new_config = Config.load(self.allocator, cli_args) catch |err| {
            std.log.warn("Config reload failed: {}", .{err});
            return;
        };
        self.surface.applyConfig(new_config);
        std.log.info("Config hot-reloaded", .{});
    }

    pub fn deinit(self: *App) void {
        // 1. Stop config watcher
        if (self.config_watcher) |*w| {
            w.deinit();
            self.config_watcher = null;
        }

        // 2. Stop render thread
        self.surface.stopRenderThread();

        // 3. Stop TermIO (reader + parser)
        self.termio.stop();

        // 4. Cleanup (reverse order of init)
        self.surface.deinit();
        self.pty.deinit();
        self.termio.deinit();
        self.window.deinit();
    }

    /// Main thread event loop (D-15: main thread does NOT do GL calls).
    pub fn run(self: *App) !void {
        while (!self.window.shouldClose()) {
            // D-13: Apply pending OSC title updates (GLFW requires main thread)
            self.surface.applyPendingTitle();

            // D-14: Poll config file watcher for hot-reload
            if (self.config_watcher) |*w| {
                w.poll();
            }

            // D-16: Adaptive event handling
            if (self.surface.scheduler.shouldRender()) {
                Window.pollEvents(); // Active: poll for low latency
            } else {
                Window.waitEventsTimeout(0.5); // Idle: wait to save CPU
            }
        }
    }
};

/// Create a screen change callback that requests a frame on the Surface.
/// Uses a function pointer closure via a static variable.
var g_surface_ptr: ?*Surface = null;

fn screenChangeCallback() void {
    if (g_surface_ptr) |surface| {
        surface.requestFrame();
    }
}

fn makeScreenChangeCallback(surface: *Surface) *const fn () void {
    g_surface_ptr = surface;
    return &screenChangeCallback;
}
