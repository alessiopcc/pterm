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

const TermIO = termio_mod.TermIO;
const TermIOConfig = termio_mod.TermIOConfig;
const Pty = pty_mod.Pty;
const Window = window_mod.Window;

pub const AppOptions = struct {
    perf_logging: bool = false,
    debug_keys: bool = false,
};

pub const App = struct {
    window: Window,
    surface: Surface,
    termio: TermIO,
    pty: Pty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, options: AppOptions) !App {
        // 1. Load config (hardcoded defaults for Phase 2)
        const config = Config{};

        // 2. Create TermIO
        var termio = try TermIO.init(allocator, TermIOConfig{
            .cols = config.cols,
            .rows = config.rows,
            .scrollback_lines = config.scrollback_lines,
        });
        errdefer termio.deinit();

        // 3. Create PTY
        var pty = try Pty.init(allocator, .{
            .cols = config.cols,
            .rows = config.rows,
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
            .family = config.font_family,
            .size_pt = config.font_size_pt,
            .dpi_scale = dpi_scale,
        };
        var temp_font = try fontgrid_mod.FontGrid.init(allocator, temp_font_config);
        const metrics = temp_font.getMetrics();
        temp_font.deinit();

        var window = try Window.init(window_mod.WindowConfig{
            .cols = config.cols,
            .rows = config.rows,
            .cell_width = metrics.cell_width,
            .cell_height = metrics.cell_height,
            .grid_padding = config.grid_padding,
            .title = config.window_title,
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
    }

    pub fn deinit(self: *App) void {
        // 1. Stop render thread
        self.surface.stopRenderThread();

        // 2. Stop TermIO (reader + parser)
        self.termio.stop();

        // 3. Cleanup (reverse order of init)
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
