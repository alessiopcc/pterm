/// OpenGL 3.3 rendering backend for the terminal grid (D-03, D-04).
///
/// Implements instanced quad rendering with three passes:
///   Pass 1: Cell backgrounds (opaque)
///   Pass 2: Glyph text (alpha-blended from atlas)
///   Pass 3: Cursor overlay (alpha-blended)
///
/// Driven by RenderState snapshots from the terminal double-buffer swap.
const std = @import("std");
const gl = @import("gl");
const shaders = @import("shaders");
const Program = @import("Program.zig").Program;
const types = @import("renderer_types");
const layout_types = @import("layout_types");

const CellInstance = types.CellInstance;
const RenderState = types.RenderState;
const CursorState = types.CursorState;
const CursorStyle = types.CursorStyle;
const Diagnostics = types.Diagnostics;
const Color = types.Color;
const palette = types.palette;

/// Maximum cells supported (300 cols x 100 rows).
const max_cells: usize = 30_000;

/// Unit quad vertices (triangle strip): 4 corners in [0,1] x [0,1].
const quad_vertices = [8]gl.float{
    0.0, 0.0, // bottom-left
    1.0, 0.0, // bottom-right
    0.0, 1.0, // top-left
    1.0, 1.0, // top-right
};

pub const OpenGLBackend = struct {
    // Shader programs (one per pass)
    bg_program: Program,
    text_program: Program,
    cursor_program: Program,

    // VAO/VBO
    quad_vao: gl.uint,
    quad_vbo: gl.uint,
    bg_instance_vbo: gl.uint,
    text_instance_vbo: gl.uint,
    cursor_instance_vbo: gl.uint,

    // Atlas textures (uploaded from GlyphAtlas pixel data)
    atlas_texture: gl.uint,
    atlas_size: u32,
    color_atlas_texture: gl.uint,
    color_atlas_size: u32,

    // Projection matrix (orthographic, updated on resize)
    projection: [16]gl.float,

    // Viewport dimensions
    viewport_width: u32,
    viewport_height: u32,

    // Icon texture for title bar logo
    icon_texture: gl.uint,
    icon_size: u32,

    // Diagnostics (D-17)
    diag: Diagnostics,

    pub const InitError = error{
        ShaderCompilation,
        ProgramLinking,
        GLResourceCreation,
    };

    /// Initialize the OpenGL backend: compile shaders, create VAO/VBOs, atlas texture.
    /// Requires an active OpenGL 3.3 context.
    pub fn init() InitError!OpenGLBackend {
        // Compile shader programs for all three passes
        const bg_program = Program.init(shaders.bg_vertex_src, shaders.bg_fragment_src) catch |e| switch (e) {
            error.ShaderCompilation => return error.ShaderCompilation,
            error.ProgramLinking => return error.ProgramLinking,
        };
        errdefer {
            var p = bg_program;
            p.deinit();
        }

        const text_program = Program.init(shaders.text_vertex_src, shaders.text_fragment_src) catch |e| switch (e) {
            error.ShaderCompilation => return error.ShaderCompilation,
            error.ProgramLinking => return error.ProgramLinking,
        };
        errdefer {
            var p = text_program;
            p.deinit();
        }

        const cursor_program = Program.init(shaders.cursor_vertex_src, shaders.cursor_fragment_src) catch |e| switch (e) {
            error.ShaderCompilation => return error.ShaderCompilation,
            error.ProgramLinking => return error.ProgramLinking,
        };
        errdefer {
            var p = cursor_program;
            p.deinit();
        }

        // Create quad VAO + VBO
        var quad_vao: gl.uint = 0;
        var quad_vbo: gl.uint = 0;
        gl.GenVertexArrays(1, @ptrCast(&quad_vao));
        gl.GenBuffers(1, @ptrCast(&quad_vbo));

        if (quad_vao == 0 or quad_vbo == 0) return error.GLResourceCreation;

        gl.BindVertexArray(quad_vao);

        // Upload unit quad
        gl.BindBuffer(gl.ARRAY_BUFFER, quad_vbo);
        gl.BufferData(
            gl.ARRAY_BUFFER,
            @intCast(@sizeOf(@TypeOf(quad_vertices))),
            &quad_vertices,
            gl.STATIC_DRAW,
        );

        // Attribute 0: vec2 quad position
        gl.EnableVertexAttribArray(0);
        gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 2 * @sizeOf(gl.float), 0);

        // Create instance VBOs
        var instance_vbos: [3]gl.uint = .{ 0, 0, 0 };
        gl.GenBuffers(3, &instance_vbos);

        const bg_instance_vbo = instance_vbos[0];
        const text_instance_vbo = instance_vbos[1];
        const cursor_instance_vbo = instance_vbos[2];

        if (bg_instance_vbo == 0 or text_instance_vbo == 0 or cursor_instance_vbo == 0)
            return error.GLResourceCreation;

        // Pre-allocate instance VBOs with DYNAMIC_DRAW
        const instance_buf_size: gl.sizeiptr = @intCast(max_cells * @sizeOf(CellInstance));
        for (instance_vbos) |vbo| {
            gl.BindBuffer(gl.ARRAY_BUFFER, vbo);
            gl.BufferData(gl.ARRAY_BUFFER, instance_buf_size, null, gl.DYNAMIC_DRAW);
        }

        // Set up instance attribute layout on the text VBO (used by all passes).
        // Each pass re-binds its own VBO before drawing, but the attribute pointers
        // are configured here once and rebound per-pass in drawFrame.
        setupInstanceAttributes(text_instance_vbo);

        // Create grayscale atlas texture (unit 0)
        var atlas_texture: gl.uint = 0;
        gl.GenTextures(1, @ptrCast(&atlas_texture));
        if (atlas_texture == 0) return error.GLResourceCreation;

        gl.BindTexture(gl.TEXTURE_2D, atlas_texture);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.BindTexture(gl.TEXTURE_2D, 0);

        // Create color (RGBA) atlas texture (unit 1) for emoji
        var color_atlas_texture: gl.uint = 0;
        gl.GenTextures(1, @ptrCast(&color_atlas_texture));
        if (color_atlas_texture == 0) return error.GLResourceCreation;

        gl.BindTexture(gl.TEXTURE_2D, color_atlas_texture);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        // Initialize with 512x512 empty RGBA data
        gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 512, 512, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
        gl.BindTexture(gl.TEXTURE_2D, 0);

        gl.BindVertexArray(0);

        // Set clear color to default background (Catppuccin Mocha #1e1e2e)
        const bg = palette.default_bg;
        gl.ClearColor(
            @as(gl.float, @floatFromInt(bg.r)) / 255.0,
            @as(gl.float, @floatFromInt(bg.g)) / 255.0,
            @as(gl.float, @floatFromInt(bg.b)) / 255.0,
            1.0,
        );

        return OpenGLBackend{
            .bg_program = bg_program,
            .text_program = text_program,
            .cursor_program = cursor_program,
            .quad_vao = quad_vao,
            .quad_vbo = quad_vbo,
            .bg_instance_vbo = bg_instance_vbo,
            .text_instance_vbo = text_instance_vbo,
            .cursor_instance_vbo = cursor_instance_vbo,
            .atlas_texture = atlas_texture,
            .atlas_size = 0,
            .color_atlas_texture = color_atlas_texture,
            .color_atlas_size = 512,
            .icon_texture = 0,
            .icon_size = 0,
            .projection = identityMatrix(),
            .viewport_width = 0,
            .viewport_height = 0,
            .diag = .{},
        };
    }

    /// Release all GL resources.
    pub fn deinit(self: *OpenGLBackend) void {
        self.bg_program.deinit();
        self.text_program.deinit();
        self.cursor_program.deinit();

        if (self.atlas_texture != 0) {
            gl.DeleteTextures(1, @ptrCast(&self.atlas_texture));
            self.atlas_texture = 0;
        }

        if (self.color_atlas_texture != 0) {
            gl.DeleteTextures(1, @ptrCast(&self.color_atlas_texture));
            self.color_atlas_texture = 0;
        }

        var vbos = [_]gl.uint{ self.quad_vbo, self.bg_instance_vbo, self.text_instance_vbo, self.cursor_instance_vbo };
        gl.DeleteBuffers(4, &vbos);
        self.quad_vbo = 0;
        self.bg_instance_vbo = 0;
        self.text_instance_vbo = 0;
        self.cursor_instance_vbo = 0;

        if (self.quad_vao != 0) {
            gl.DeleteVertexArrays(1, @ptrCast(&self.quad_vao));
            self.quad_vao = 0;
        }
    }

    /// Update viewport and recompute orthographic projection matrix on window resize.
    pub fn resize(self: *OpenGLBackend, width: u32, height: u32) void {
        self.viewport_width = width;
        self.viewport_height = height;
        gl.Viewport(0, 0, @intCast(width), @intCast(height));
        self.projection = computeOrthoMatrix(
            0.0,
            @floatFromInt(width),
            @floatFromInt(height),
            0.0,
            -1.0,
            1.0,
        );
    }

    /// Upload glyph atlas pixel data (single-channel R8) to the atlas texture.
    pub fn uploadAtlas(self: *OpenGLBackend, pixels: []const u8, size: u32) void {
        gl.BindTexture(gl.TEXTURE_2D, self.atlas_texture);
        if (self.atlas_size == size) {
            // Same size: use sub-image update to avoid reallocation
            gl.TexSubImage2D(
                gl.TEXTURE_2D,
                0,
                0,
                0,
                @intCast(size),
                @intCast(size),
                gl.RED,
                gl.UNSIGNED_BYTE,
                pixels.ptr,
            );
        } else {
            gl.TexImage2D(
                gl.TEXTURE_2D,
                0,
                gl.R8,
                @intCast(size),
                @intCast(size),
                0,
                gl.RED,
                gl.UNSIGNED_BYTE,
                pixels.ptr,
            );
            self.atlas_size = size;
        }
        gl.BindTexture(gl.TEXTURE_2D, 0);
    }

    /// Upload color (RGBA) atlas pixel data to the color atlas texture (unit 1).
    pub fn uploadColorAtlas(self: *OpenGLBackend, pixels: []const u8, size: u32) void {
        gl.ActiveTexture(gl.TEXTURE1);
        gl.BindTexture(gl.TEXTURE_2D, self.color_atlas_texture);
        if (self.color_atlas_size == size) {
            gl.TexSubImage2D(
                gl.TEXTURE_2D,
                0,
                0,
                0,
                @intCast(size),
                @intCast(size),
                gl.RGBA,
                gl.UNSIGNED_BYTE,
                pixels.ptr,
            );
        } else {
            gl.TexImage2D(
                gl.TEXTURE_2D,
                0,
                gl.RGBA8,
                @intCast(size),
                @intCast(size),
                0,
                gl.RGBA,
                gl.UNSIGNED_BYTE,
                pixels.ptr,
            );
            self.color_atlas_size = size;
        }
        gl.ActiveTexture(gl.TEXTURE0);
    }

    /// Draw a complete frame from a RenderState snapshot.
    /// Three-pass pipeline: backgrounds, text, cursor (D-04).
    /// Accepts an optional background color for clear; uses default palette if null.
    pub fn drawFrame(self: *OpenGLBackend, state: *const types.RenderState, bg_color: ?Color) void {
        const start_ns = std.time.nanoTimestamp();

        // Set clear color from config palette (if provided) or keep init-time default
        if (bg_color) |bg| {
            gl.ClearColor(
                @as(gl.float, @floatFromInt(bg.r)) / 255.0,
                @as(gl.float, @floatFromInt(bg.g)) / 255.0,
                @as(gl.float, @floatFromInt(bg.b)) / 255.0,
                1.0,
            );
        }

        gl.BindVertexArray(self.quad_vao);
        gl.Clear(gl.COLOR_BUFFER_BIT);

        self.diag.draw_calls = 0;

        const grid_offset_x = state.grid_padding;
        const grid_offset_y = state.grid_padding;

        // ---- Pass 1: Cell Backgrounds (D-04) ----
        {
            self.bg_program.use();
            self.bg_program.setUniformMat4("uProjection", self.projection);
            self.bg_program.setUniformVec2("uCellSize", state.cell_width, state.cell_height);
            self.bg_program.setUniformVec2("uGridOffset", grid_offset_x, grid_offset_y);

            // No blending for opaque backgrounds (Pitfall 6: explicit state per pass)
            gl.Disable(gl.BLEND);

            const bg_count = state.bg_cells.len;
            if (bg_count > 0) {
                gl.BindBuffer(gl.ARRAY_BUFFER, self.bg_instance_vbo);
                gl.BufferSubData(
                    gl.ARRAY_BUFFER,
                    0,
                    @intCast(bg_count * @sizeOf(CellInstance)),
                    @ptrCast(state.bg_cells.ptr),
                );
                setupInstanceAttributes(self.bg_instance_vbo);
                gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, @intCast(bg_count));
                self.diag.draw_calls += 1;
            }
        }

        // ---- Pass 2: Text Glyphs (D-04) ----
        {
            self.text_program.use();
            self.text_program.setUniformMat4("uProjection", self.projection);
            self.text_program.setUniformVec2("uCellSize", state.cell_width, state.cell_height);
            self.text_program.setUniformVec2("uGridOffset", grid_offset_x, grid_offset_y);
            self.text_program.setUniformFloat("uTextScale", 1.0);
            self.text_program.setUniformVec2(
                "uAtlasSize",
                @floatFromInt(self.atlas_size),
                @floatFromInt(self.atlas_size),
            );
            self.text_program.setUniformVec2(
                "uColorAtlasSize",
                @floatFromInt(self.color_atlas_size),
                @floatFromInt(self.color_atlas_size),
            );

            // Alpha blending for text (Pitfall 6: explicit state per pass)
            gl.Enable(gl.BLEND);
            gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

            // Bind grayscale atlas texture to unit 0
            gl.ActiveTexture(gl.TEXTURE0);
            gl.BindTexture(gl.TEXTURE_2D, self.atlas_texture);
            self.text_program.setUniformInt("uAtlasTexture", 0);

            // Bind color (RGBA) atlas texture to unit 1
            gl.ActiveTexture(gl.TEXTURE1);
            gl.BindTexture(gl.TEXTURE_2D, self.color_atlas_texture);
            self.text_program.setUniformInt("uColorAtlasTexture", 1);

            const text_count = state.cells.len;
            if (text_count > 0) {
                gl.BindBuffer(gl.ARRAY_BUFFER, self.text_instance_vbo);
                gl.BufferSubData(
                    gl.ARRAY_BUFFER,
                    0,
                    @intCast(text_count * @sizeOf(CellInstance)),
                    @ptrCast(state.cells.ptr),
                );
                setupInstanceAttributes(self.text_instance_vbo);
                gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, @intCast(text_count));
                self.diag.draw_calls += 1;
            }
        }

        // ---- Pass 3: Cursor Overlay (D-04) ----
        if (state.cursor.visible) {
            self.cursor_program.use();
            self.cursor_program.setUniformMat4("uProjection", self.projection);
            self.cursor_program.setUniformVec2("uCellSize", state.cell_width, state.cell_height);
            self.cursor_program.setUniformVec2("uGridOffset", grid_offset_x, grid_offset_y);

            // Alpha blending for cursor (Pitfall 6: explicit state per pass)
            gl.Enable(gl.BLEND);
            gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

            const cursor_instance = buildCursorInstance(state.cursor);
            gl.BindBuffer(gl.ARRAY_BUFFER, self.cursor_instance_vbo);
            gl.BufferSubData(
                gl.ARRAY_BUFFER,
                0,
                @intCast(@sizeOf(CellInstance)),
                @ptrCast(&cursor_instance),
            );
            setupInstanceAttributes(self.cursor_instance_vbo);
            gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, 1);
            self.diag.draw_calls += 1;
        }

        gl.BindVertexArray(0);

        // Record frame timing (D-17)
        const end_ns = std.time.nanoTimestamp();
        const elapsed_ns = end_ns - start_ns;
        self.diag.frame_time_us = if (elapsed_ns > 0)
            @intCast(@divFloor(elapsed_ns, 1000))
        else
            0;
    }

    /// Return current diagnostics snapshot.
    pub fn getDiagnostics(self: *const OpenGLBackend) Diagnostics {
        return self.diag;
    }

    /// Draw a complete frame within a specific pixel rectangle (viewport/scissor).
    /// Used by the Compositor to render individual panes in their allocated screen areas.
    /// GL origin is bottom-left; this method converts from top-left Rect coordinates.
    pub fn drawFrameInRect(self: *OpenGLBackend, state: *const types.RenderState, bg_color: ?Color, rect: layout_types.Rect) void {
        // GL origin is bottom-left; convert from top-left Rect coordinates
        const gl_y: i32 = @as(i32, @intCast(self.viewport_height)) - rect.y - @as(i32, @intCast(rect.h));
        gl.Viewport(@intCast(rect.x), gl_y, @intCast(rect.w), @intCast(rect.h));
        gl.Enable(gl.SCISSOR_TEST);
        gl.Scissor(@intCast(rect.x), gl_y, @intCast(rect.w), @intCast(rect.h));

        // Recompute projection for this pane's dimensions
        self.projection = computeOrthoMatrix(0.0, @floatFromInt(rect.w), @floatFromInt(rect.h), 0.0, -1.0, 1.0);

        // Delegate to existing drawFrame (clears within scissor, runs 3-pass pipeline)
        self.drawFrame(state, bg_color);

        gl.Disable(gl.SCISSOR_TEST);
    }

    /// Draw a filled rectangle with a solid color. Used for tab bar backgrounds,
    /// pane borders, and other UI chrome elements.
    /// Uses the bg_program shader with a single CellInstance covering the rect.
    pub fn drawFilledRect(self: *OpenGLBackend, rect: layout_types.Rect, color: Color) void {
        // Set viewport to full window, use scissor to clip to rect
        gl.Viewport(0, 0, @intCast(self.viewport_width), @intCast(self.viewport_height));
        const gl_y: i32 = @as(i32, @intCast(self.viewport_height)) - rect.y - @as(i32, @intCast(rect.h));
        gl.Enable(gl.SCISSOR_TEST);
        gl.Scissor(@intCast(rect.x), gl_y, @intCast(rect.w), @intCast(rect.h));

        // Use full-window orthographic projection
        const proj = computeOrthoMatrix(0.0, @floatFromInt(self.viewport_width), @floatFromInt(self.viewport_height), 0.0, -1.0, 1.0);

        self.bg_program.use();
        self.bg_program.setUniformMat4("uProjection", proj);
        // Use the rect dimensions as the "cell size" so one instance fills the area
        self.bg_program.setUniformVec2("uCellSize", @floatFromInt(rect.w), @floatFromInt(rect.h));
        self.bg_program.setUniformVec2("uGridOffset", @floatFromInt(rect.x), @floatFromInt(rect.y));

        gl.Disable(gl.BLEND);

        // Create a single CellInstance at grid position (0,0) with the desired bg color
        const instance = CellInstance{
            .grid_col = 0,
            .grid_row = 0,
            .atlas_x = 0,
            .atlas_y = 0,
            .atlas_w = 0,
            .atlas_h = 0,
            .bearing_x = 0,
            .bearing_y = 0,
            .fg_color = 0,
            .bg_color = color.toU32(),
            .flags = 0,
        };

        gl.BindVertexArray(self.quad_vao);
        gl.BindBuffer(gl.ARRAY_BUFFER, self.bg_instance_vbo);
        gl.BufferSubData(gl.ARRAY_BUFFER, 0, @intCast(@sizeOf(CellInstance)), @ptrCast(&instance));
        setupInstanceAttributes(self.bg_instance_vbo);
        gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, 1);
        gl.BindVertexArray(0);

        gl.Disable(gl.SCISSOR_TEST);
    }

    /// Draw a filled rectangle with alpha blending enabled.
    /// Used for semi-transparent overlays (bell flash D-27).
    pub fn drawFilledRectAlpha(self: *OpenGLBackend, rect: layout_types.Rect, color: Color) void {
        gl.Viewport(0, 0, @intCast(self.viewport_width), @intCast(self.viewport_height));
        const gl_y: i32 = @as(i32, @intCast(self.viewport_height)) - rect.y - @as(i32, @intCast(rect.h));
        gl.Enable(gl.SCISSOR_TEST);
        gl.Scissor(@intCast(rect.x), gl_y, @intCast(rect.w), @intCast(rect.h));

        const proj = computeOrthoMatrix(0.0, @floatFromInt(self.viewport_width), @floatFromInt(self.viewport_height), 0.0, -1.0, 1.0);

        self.bg_program.use();
        self.bg_program.setUniformMat4("uProjection", proj);
        self.bg_program.setUniformVec2("uCellSize", @floatFromInt(rect.w), @floatFromInt(rect.h));
        self.bg_program.setUniformVec2("uGridOffset", @floatFromInt(rect.x), @floatFromInt(rect.y));

        // Enable alpha blending for semi-transparent overlay
        gl.Enable(gl.BLEND);
        gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

        const instance = CellInstance{
            .grid_col = 0,
            .grid_row = 0,
            .atlas_x = 0,
            .atlas_y = 0,
            .atlas_w = 0,
            .atlas_h = 0,
            .bearing_x = 0,
            .bearing_y = 0,
            .fg_color = 0,
            .bg_color = color.toU32(),
            .flags = 0,
        };

        gl.BindVertexArray(self.quad_vao);
        gl.BindBuffer(gl.ARRAY_BUFFER, self.bg_instance_vbo);
        gl.BufferSubData(gl.ARRAY_BUFFER, 0, @intCast(@sizeOf(CellInstance)), @ptrCast(&instance));
        setupInstanceAttributes(self.bg_instance_vbo);
        gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, 1);
        gl.BindVertexArray(0);

        gl.Disable(gl.BLEND);
        gl.Disable(gl.SCISSOR_TEST);
    }

    /// Upload RGBA icon pixels for title bar logo rendering.
    pub fn uploadIcon(self: *OpenGLBackend, pixels: []const u8, size: u32) void {
        if (self.icon_texture == 0) {
            gl.GenTextures(1, @ptrCast(&self.icon_texture));
        }
        gl.BindTexture(gl.TEXTURE_2D, self.icon_texture);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.TexImage2D(
            gl.TEXTURE_2D,
            0,
            gl.RGBA,
            @intCast(size),
            @intCast(size),
            0,
            gl.RGBA,
            gl.UNSIGNED_BYTE,
            @ptrCast(pixels.ptr),
        );
        self.icon_size = size;
    }

    /// Draw the icon at a pixel position with a given display size.
    /// Uses the color atlas shader (text_program) with a single instance whose
    /// atlas coords span the full icon texture.
    pub fn drawIcon(self: *OpenGLBackend, px_x: i32, px_y: i32, display_size: u32) void {
        if (self.icon_texture == 0 or self.icon_size == 0) return;

        const proj = computeOrthoMatrix(0.0, @floatFromInt(self.viewport_width), @floatFromInt(self.viewport_height), 0.0, -1.0, 1.0);
        gl.Viewport(0, 0, @intCast(self.viewport_width), @intCast(self.viewport_height));
        gl.Disable(gl.SCISSOR_TEST);

        self.text_program.use();
        self.text_program.setUniformMat4("uProjection", proj);
        self.text_program.setUniformVec2("uCellSize", @floatFromInt(display_size), @floatFromInt(display_size));
        self.text_program.setUniformVec2("uGridOffset", @floatFromInt(px_x), @floatFromInt(px_y));
        self.text_program.setUniformFloat("uTextScale", 1.0);
        self.text_program.setUniformVec2("uAtlasSize", @floatFromInt(self.icon_size), @floatFromInt(self.icon_size));
        self.text_program.setUniformVec2("uColorAtlasSize", @floatFromInt(self.icon_size), @floatFromInt(self.icon_size));

        gl.Enable(gl.BLEND);
        gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

        // Bind icon texture to both texture units (color glyph path)
        gl.ActiveTexture(gl.TEXTURE0);
        gl.BindTexture(gl.TEXTURE_2D, self.icon_texture);
        self.text_program.setUniformInt("uAtlasTexture", 0);
        gl.ActiveTexture(gl.TEXTURE1);
        gl.BindTexture(gl.TEXTURE_2D, self.icon_texture);
        self.text_program.setUniformInt("uColorAtlasTexture", 1);

        // Single instance: grid pos (0,0), atlas covers full icon, color glyph flag
        const instance = CellInstance{
            .grid_col = 0,
            .grid_row = 0,
            .atlas_x = 0,
            .atlas_y = 0,
            .atlas_w = @intCast(self.icon_size),
            .atlas_h = @intCast(self.icon_size),
            .bearing_x = 0,
            .bearing_y = 0,
            .fg_color = 0xFFFFFFFF,
            .bg_color = 0,
            .flags = 0x0010, // COLOR_GLYPH flag — use color atlas path
        };

        gl.BindVertexArray(self.quad_vao);
        gl.BindBuffer(gl.ARRAY_BUFFER, self.text_instance_vbo);
        gl.BufferSubData(gl.ARRAY_BUFFER, 0, @intCast(@sizeOf(CellInstance)), @ptrCast(&instance));
        setupInstanceAttributes(self.text_instance_vbo);
        gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, 1);
        gl.BindVertexArray(0);

        // Restore atlas textures
        gl.ActiveTexture(gl.TEXTURE0);
        gl.BindTexture(gl.TEXTURE_2D, self.atlas_texture);
        gl.ActiveTexture(gl.TEXTURE1);
        gl.BindTexture(gl.TEXTURE_2D, self.color_atlas_texture);
    }

    /// Restore viewport to full window dimensions and disable scissor test.
    /// Call after per-pane rendering to reset GL state for full-window operations.
    pub fn setFullViewport(self: *OpenGLBackend) void {
        gl.Viewport(0, 0, @intCast(self.viewport_width), @intCast(self.viewport_height));
        gl.Disable(gl.SCISSOR_TEST);
        self.projection = computeOrthoMatrix(
            0.0,
            @floatFromInt(self.viewport_width),
            @floatFromInt(self.viewport_height),
            0.0,
            -1.0,
            1.0,
        );
    }

    // -- Private helpers ------------------------------------------------

    /// Set up per-instance vertex attributes matching CellInstance layout.
    /// Must be called with the desired instance VBO already bound to GL_ARRAY_BUFFER
    /// (or pass the VBO to bind it here).
    pub fn setupInstanceAttributes(instance_vbo: gl.uint) void {
        gl.BindBuffer(gl.ARRAY_BUFFER, instance_vbo);

        const stride: gl.sizei = @intCast(@sizeOf(CellInstance));

        // Attribute 1: grid_col, grid_row (uvec2, offset 0)
        gl.EnableVertexAttribArray(1);
        gl.VertexAttribIPointer(1, 2, gl.UNSIGNED_SHORT, stride, 0);
        gl.VertexAttribDivisor(1, 1);

        // Attribute 2: atlas_x, atlas_y, atlas_w, atlas_h (uvec4 as 4x u16, offset 4)
        gl.EnableVertexAttribArray(2);
        gl.VertexAttribIPointer(2, 4, gl.UNSIGNED_SHORT, stride, 4);
        gl.VertexAttribDivisor(2, 1);

        // Attribute 3: bearing_x, bearing_y (ivec2, offset 12)
        gl.EnableVertexAttribArray(3);
        gl.VertexAttribIPointer(3, 2, gl.SHORT, stride, 12);
        gl.VertexAttribDivisor(3, 1);

        // Attribute 4: fg_color (uint, offset 16)
        gl.EnableVertexAttribArray(4);
        gl.VertexAttribIPointer(4, 1, gl.UNSIGNED_INT, stride, 16);
        gl.VertexAttribDivisor(4, 1);

        // Attribute 5: bg_color (uint, offset 20)
        gl.EnableVertexAttribArray(5);
        gl.VertexAttribIPointer(5, 1, gl.UNSIGNED_INT, stride, 20);
        gl.VertexAttribDivisor(5, 1);

        // Attribute 6: flags (uint packed from u16, offset 24)
        gl.EnableVertexAttribArray(6);
        gl.VertexAttribIPointer(6, 1, gl.UNSIGNED_SHORT, stride, 24);
        gl.VertexAttribDivisor(6, 1);
    }

    /// Build a CellInstance from cursor state for Pass 3.
    fn buildCursorInstance(cursor: CursorState) CellInstance {
        const style_flag: u16 = switch (cursor.style) {
            .block => 0,
            .ibeam => 1,
            .underline => 2,
            .hollow => 3,
        };
        return CellInstance{
            .grid_col = cursor.col,
            .grid_row = cursor.row,
            .atlas_x = 0,
            .atlas_y = 0,
            .atlas_w = 0,
            .atlas_h = 0,
            .bearing_x = 0,
            .bearing_y = 0,
            .fg_color = cursor.color,
            .bg_color = 0,
            .flags = style_flag,
        };
    }
};

/// Compute a column-major orthographic projection matrix.
/// Maps (left..right, bottom..top, near..far) to OpenGL NDC (-1..1).
pub fn computeOrthoMatrix(
    left: f32,
    right: f32,
    bottom: f32,
    top: f32,
    near: f32,
    far: f32,
) [16]gl.float {
    const rl = right - left;
    const tb = top - bottom;
    const fn_ = far - near;

    // Column-major layout: m[col * 4 + row]
    return [16]gl.float{
        2.0 / rl, 0.0, 0.0, 0.0, // col 0
        0.0, 2.0 / tb, 0.0, 0.0, // col 1
        0.0, 0.0, -2.0 / fn_, 0.0, // col 2
        -(right + left) / rl, -(top + bottom) / tb, -(far + near) / fn_, 1.0, // col 3
    };
}

/// Returns a 4x4 identity matrix in column-major order.
fn identityMatrix() [16]gl.float {
    return [16]gl.float{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
}
