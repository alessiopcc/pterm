/// GLFW window wrapper with cell-grid resize and GL context detach (D-14, D-15).
///
/// Provides a thin abstraction over GLFW for:
///   - Window creation with OpenGL 3.3 core profile hints
///   - DPI-aware pixel size computation from cell grid dimensions
///   - GL context attach/detach for render thread handoff (D-15)
///   - Callback registration for input, resize, and focus events
const std = @import("std");
const glfw = @import("zglfw");
const icon = @import("icon");

pub const WindowConfig = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    cell_width: f32,
    cell_height: f32,
    grid_padding: f32 = 4.0,
    chrome_height: u32 = 0, // Title bar + tab bar height in pixels
    title: [:0]const u8 = "PTerm",
};

pub const Callbacks = struct {
    key_callback: ?glfw.KeyFn = null,
    char_callback: ?glfw.CharFn = null,
    framebuffer_size_callback: ?glfw.FramebufferSizeFn = null,
    focus_callback: ?glfw.WindowFocusFn = null,
    scroll_callback: ?glfw.ScrollFn = null,
    content_scale_callback: ?glfw.WindowContentScaleFn = null,
    mouse_button_callback: ?glfw.MouseButtonFn = null,
    cursor_pos_callback: ?glfw.CursorPosFn = null,
};

pub const Window = struct {
    handle: *glfw.Window,
    content_scale: f32,

    pub fn init(config: WindowConfig) !Window {
        glfw.init() catch {
            return error.GlfwInitFailed;
        };
        errdefer glfw.terminate();

        // Compute pixel dimensions from cell grid
        const pixel_width: c_int = @intFromFloat(
            @as(f32, @floatFromInt(config.cols)) * config.cell_width + 2.0 * config.grid_padding,
        );
        const pixel_height: c_int = @intFromFloat(
            @as(f32, @floatFromInt(config.rows)) * config.cell_height + @as(f32, @floatFromInt(config.chrome_height)),
        );

        // OpenGL 3.3 core profile hints (required on macOS per Pitfall 1)
        glfw.windowHint(.context_version_major, 3);
        glfw.windowHint(.context_version_minor, 3);
        glfw.windowHint(.opengl_profile, .opengl_core_profile);
        glfw.windowHint(.opengl_forward_compat, true);

        // Frameless window — PTerm renders its own tab bar with window controls
        glfw.windowHint(.decorated, false);

        const handle = glfw.createWindow(
            pixel_width,
            pixel_height,
            config.title,
            null,
            null,
        ) catch return error.WindowCreationFailed;

        // Set window icon (taskbar + title bar on Windows/Linux)
        icon.setWindowIcon(handle);

        // Query DPI scale
        const scale = handle.getContentScale();
        const dpi_scale = scale[0]; // Use x-scale (typically same as y)

        return Window{
            .handle = handle,
            .content_scale = dpi_scale,
        };
    }

    pub fn deinit(self: *Window) void {
        self.handle.destroy();
        glfw.terminate();
    }

    pub fn shouldClose(self: *const Window) bool {
        return self.handle.shouldClose();
    }

    pub fn swapBuffers(self: *Window) void {
        self.handle.swapBuffers();
    }

    pub fn getFramebufferSize(self: *const Window) struct { width: u32, height: u32 } {
        const size = self.handle.getFramebufferSize();
        return .{
            .width = @intCast(size[0]),
            .height = @intCast(size[1]),
        };
    }

    pub fn getContentScale(self: *const Window) f32 {
        return self.content_scale;
    }

    /// Get the window size in screen coordinates (not framebuffer pixels).
    pub fn getSize(self: *const Window) struct { width: i32, height: i32 } {
        const size = self.handle.getSize();
        return .{ .width = size[0], .height = size[1] };
    }

    /// Set the window size in screen coordinates.
    pub fn setSize(self: *Window, width: i32, height: i32) void {
        self.handle.setSize(width, height);
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        self.handle.setTitle(title);
    }

    /// Acquire the GL context on the current thread (render thread).
    pub fn makeContextCurrent(self: *Window) void {
        glfw.makeContextCurrent(self.handle);
    }

    /// Release the GL context from the current thread (D-15 context handoff).
    pub fn detachContext() void {
        glfw.makeContextCurrent(null);
    }

    /// Register GLFW event callbacks.
    pub fn setCallbacks(self: *Window, cbs: Callbacks) void {
        if (cbs.key_callback) |cb| _ = self.handle.setKeyCallback(cb);
        if (cbs.char_callback) |cb| _ = self.handle.setCharCallback(cb);
        if (cbs.framebuffer_size_callback) |cb| _ = self.handle.setFramebufferSizeCallback(cb);
        if (cbs.focus_callback) |cb| _ = self.handle.setFocusCallback(cb);
        if (cbs.scroll_callback) |cb| _ = self.handle.setScrollCallback(cb);
        if (cbs.content_scale_callback) |cb| _ = self.handle.setContentScaleCallback(cb);
        if (cbs.mouse_button_callback) |cb| _ = self.handle.setMouseButtonCallback(cb);
        if (cbs.cursor_pos_callback) |cb| _ = self.handle.setCursorPosCallback(cb);
    }

    /// Set the user pointer for GLFW callback context.
    pub fn setUserPointer(self: *Window, ptr: ?*anyopaque) void {
        self.handle.setUserPointer(ptr);
    }

    /// Get the user pointer from GLFW callback context.
    pub fn getUserPointer(comptime T: type, handle: *glfw.Window) ?*T {
        return handle.getUserPointer(T);
    }

    /// Iconify (minimize) the window.
    pub fn iconify(self: *Window) void {
        self.handle.iconify();
    }

    /// Maximize or restore the window.
    pub fn toggleMaximize(self: *Window) void {
        if (self.handle.getAttribute(.maximized)) {
            self.handle.restore();
        } else {
            self.handle.maximize();
        }
    }

    /// Request window close.
    pub fn requestClose(self: *Window) void {
        self.handle.setShouldClose(true);
    }

    /// Get the window position in screen coordinates.
    pub fn getPos(self: *const Window) struct { x: i32, y: i32 } {
        const pos = self.handle.getPos();
        return .{ .x = pos[0], .y = pos[1] };
    }

    /// Set the window position in screen coordinates.
    pub fn setPos(self: *Window, x: i32, y: i32) void {
        self.handle.setPos(x, y);
    }

    /// Check if the window is maximized.
    pub fn isMaximized(self: *const Window) bool {
        return self.handle.getAttribute(.maximized);
    }

    /// Poll events (main thread only).
    pub fn pollEvents() void {
        glfw.pollEvents();
    }

    /// Wait for events with timeout (main thread only, D-16 idle savings).
    pub fn waitEventsTimeout(timeout: f64) void {
        glfw.waitEventsTimeout(timeout);
    }
};
