/// Renderer abstraction layer (D-06).
/// OpenGL implements this. Metal plugs in later.
const types = @import("types");
const OpenGLBackend = @import("opengl_backend").OpenGLBackend;
const RenderState = types.RenderState;
const Diagnostics = types.Diagnostics;
const Color = types.Color;

/// Renderer abstraction layer (D-06).
/// OpenGL implements this. Metal plugs in later.
pub const Renderer = union(enum) {
    opengl: *OpenGLBackend,

    pub fn drawFrame(self: Renderer, state: *const RenderState, bg_color: ?Color) void {
        switch (self) {
            .opengl => |backend| backend.drawFrame(state, bg_color),
        }
    }

    pub fn resize(self: Renderer, width: u32, height: u32) void {
        switch (self) {
            .opengl => |backend| backend.resize(width, height),
        }
    }

    pub fn getDiagnostics(self: Renderer) Diagnostics {
        switch (self) {
            .opengl => |backend| return backend.getDiagnostics(),
        }
    }

    pub fn uploadAtlas(self: Renderer, pixels: []const u8, size: u32) void {
        switch (self) {
            .opengl => |backend| backend.uploadAtlas(pixels, size),
        }
    }

    pub fn deinit(self: Renderer) void {
        switch (self) {
            .opengl => |backend| backend.deinit(),
        }
    }
};
