/// OpenGL shader program compilation and uniform management.
///
/// Compiles vertex + fragment shaders, links them into a program,
/// and provides uniform setters for common types.
const std = @import("std");
const gl = @import("gl");

pub const Program = struct {
    id: gl.uint,

    pub const Error = error{
        ShaderCompilation,
        ProgramLinking,
    };

    /// Compile vertex + fragment shaders and link into a program.
    pub fn init(vertex_src: [*:0]const u8, fragment_src: [*:0]const u8) Error!Program {
        // Compile vertex shader
        const vs = gl.CreateShader(gl.VERTEX_SHADER);
        if (vs == 0) return error.ShaderCompilation;
        defer gl.DeleteShader(vs);

        gl.ShaderSource(vs, 1, @ptrCast(&vertex_src), null);
        gl.CompileShader(vs);

        var vs_status: gl.int = 0;
        gl.GetShaderiv(vs, gl.COMPILE_STATUS, @ptrCast(&vs_status));
        if (vs_status == 0) {
            logShaderError(vs);
            return error.ShaderCompilation;
        }

        // Compile fragment shader
        const fs = gl.CreateShader(gl.FRAGMENT_SHADER);
        if (fs == 0) return error.ShaderCompilation;
        defer gl.DeleteShader(fs);

        gl.ShaderSource(fs, 1, @ptrCast(&fragment_src), null);
        gl.CompileShader(fs);

        var fs_status: gl.int = 0;
        gl.GetShaderiv(fs, gl.COMPILE_STATUS, @ptrCast(&fs_status));
        if (fs_status == 0) {
            logShaderError(fs);
            return error.ShaderCompilation;
        }

        // Link program
        const program = gl.CreateProgram();
        if (program == 0) return error.ProgramLinking;

        gl.AttachShader(program, vs);
        gl.AttachShader(program, fs);
        gl.LinkProgram(program);

        var link_status: gl.int = 0;
        gl.GetProgramiv(program, gl.LINK_STATUS, @ptrCast(&link_status));
        if (link_status == 0) {
            logProgramError(program);
            gl.DeleteProgram(program);
            return error.ProgramLinking;
        }

        return Program{ .id = program };
    }

    /// Delete the shader program and release GL resources.
    pub fn deinit(self: *Program) void {
        if (self.id != 0) {
            gl.DeleteProgram(self.id);
            self.id = 0;
        }
    }

    /// Bind this program for use in subsequent draw calls.
    pub fn use(self: *const Program) void {
        gl.UseProgram(self.id);
    }

    /// Set a mat4 uniform by name.
    pub fn setUniformMat4(self: *const Program, name: [*:0]const u8, matrix: [16]gl.float) void {
        const loc = gl.GetUniformLocation(self.id, name);
        if (loc >= 0) {
            gl.UniformMatrix4fv(loc, 1, gl.FALSE, @ptrCast(&matrix));
        }
    }

    /// Set a vec2 uniform by name.
    pub fn setUniformVec2(self: *const Program, name: [*:0]const u8, x: gl.float, y: gl.float) void {
        const loc = gl.GetUniformLocation(self.id, name);
        if (loc >= 0) {
            gl.Uniform2f(loc, x, y);
        }
    }

    /// Set an int uniform by name.
    pub fn setUniformInt(self: *const Program, name: [*:0]const u8, value: gl.int) void {
        const loc = gl.GetUniformLocation(self.id, name);
        if (loc >= 0) {
            gl.Uniform1i(loc, value);
        }
    }

    // -- Private helpers ------------------------------------------------

    fn logShaderError(shader: gl.uint) void {
        var log_len: gl.int = 0;
        gl.GetShaderiv(shader, gl.INFO_LOG_LENGTH, @ptrCast(&log_len));
        if (log_len > 0) {
            var buf: [1024]u8 = undefined;
            const read_len: gl.sizei = @intCast(@min(@as(usize, @intCast(log_len)), buf.len));
            gl.GetShaderInfoLog(shader, read_len, null, &buf);
            std.log.err("Shader compilation error: {s}", .{buf[0..@intCast(read_len)]});
        }
    }

    fn logProgramError(program: gl.uint) void {
        var log_len: gl.int = 0;
        gl.GetProgramiv(program, gl.INFO_LOG_LENGTH, @ptrCast(&log_len));
        if (log_len > 0) {
            var buf: [1024]u8 = undefined;
            const read_len: gl.sizei = @intCast(@min(@as(usize, @intCast(log_len)), buf.len));
            gl.GetProgramInfoLog(program, read_len, null, &buf);
            std.log.err("Program linking error: {s}", .{buf[0..@intCast(read_len)]});
        }
    }
};
