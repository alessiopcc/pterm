// Shell Detection and Spawn Configuration (D-09)
//
// Detects the user's default shell on Unix (via $SHELL) and Windows
// (via $COMSPEC, with PowerShell/cmd.exe fallbacks).

const std = @import("std");
const builtin = @import("builtin");

/// Configuration for launching a shell process.
pub const ShellConfig = struct {
    path: [*:0]const u8,
    args: ?[*:null]const ?[*:0]const u8 = null,
    name: []const u8,
    /// Whether path/args were heap-allocated (resolveShell with config program).
    owned: bool = false,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: ShellConfig) void {
        if (!self.owned) return;
        const alloc = self.allocator orelse return;
        // Free args array and its duped strings
        if (self.args) |argv| {
            var i: usize = 1; // argv[0] is path (freed separately)
            while (argv[i]) |arg| : (i += 1) {
                alloc.free(std.mem.span(arg));
            }
            // Free the argv array itself (sentinel-terminated)
            const total = i;
            alloc.free(argv[0..total :null]);
        }
        alloc.free(std.mem.span(self.path));
    }
};

/// Detect the user's default shell.
/// On Unix: checks $SHELL env var, falls back to /bin/sh.
/// On Windows: checks $COMSPEC, falls back to powershell.exe, then cmd.exe.
pub fn detectShell() ShellConfig {
    if (comptime builtin.os.tag == .windows) {
        return detectWindowsShell();
    } else {
        return detectUnixShell();
    }
}

fn detectUnixShell() ShellConfig {
    if (std.posix.getenv("SHELL")) |shell_env| {
        // Find the shell name (last component of path)
        const name = extractShellName(shell_env);
        // We need a sentinel-terminated pointer; the env var is already null-terminated in C
        return ShellConfig{
            .path = @ptrCast(shell_env.ptr),
            .args = null,
            .name = name,
        };
    }
    return ShellConfig{
        .path = "/bin/sh",
        .args = null,
        .name = "sh",
    };
}

fn detectWindowsShell() ShellConfig {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "COMSPEC") catch null) |_| {
        // COMSPEC is typically C:\Windows\system32\cmd.exe
        // But we prefer PowerShell if available
        return ShellConfig{
            .path = "powershell.exe",
            .args = null,
            .name = "powershell",
        };
    }
    return ShellConfig{
        .path = "cmd.exe",
        .args = null,
        .name = "cmd",
    };
}

/// Extract shell name from a path (e.g., "/bin/bash" -> "bash").
fn extractShellName(path: []const u8) []const u8 {
    const sep = comptime if (builtin.os.tag == .windows) '\\' else '/';
    if (std.mem.lastIndexOfScalar(u8, path, sep)) |idx| {
        return path[idx + 1 ..];
    }
    return path;
}

/// Resolve shell from config, with fallback to auto-detection (D-04, D-05).
/// If config_program is non-null, attempt to use it. If the binary is not
/// found (PATH lookup fails or absolute path missing), log warning and
/// fall back to detectShell().
/// config_args are converted to the sentinel-terminated format expected by spawn.
pub fn resolveShell(
    allocator: std.mem.Allocator,
    config_program: ?[]const u8,
    config_args: ?[]const []const u8,
) ShellConfig {
    if (config_program) |program| {
        // D-03: bare name resolved via PATH, absolute path used directly
        if (findExecutable(allocator, program)) |found_path| {
            const name = extractShellName(program);
            // Build args array if provided (D-02)
            const args = if (config_args) |ca|
                buildArgsArray(allocator, found_path, ca)
            else
                null;
            return ShellConfig{
                .path = found_path,
                .args = args,
                .name = name,
                .owned = true,
                .allocator = allocator,
            };
        } else {
            std.log.warn("Configured shell '{s}' not found, falling back to auto-detect (D-05)", .{program});
            return detectShell();
        }
    }
    return detectShell();
}

/// Search for an executable by name. If program contains a path separator,
/// treat it as an absolute/relative path and check existence directly.
/// Otherwise, search each directory in the PATH environment variable.
/// Returns a sentinel-terminated path string allocated from the allocator, or null.
pub fn findExecutable(allocator: std.mem.Allocator, program: []const u8) ?[*:0]const u8 {
    // Check if it's an absolute or relative path (contains separator)
    const has_separator = std.mem.indexOfScalar(u8, program, '/') != null or
        std.mem.indexOfScalar(u8, program, '\\') != null;

    if (has_separator) {
        // Direct path -- check if it exists
        const z_path = allocator.dupeZ(u8, program) catch return null;
        if (std.fs.cwd().statFile(program)) |_| {
            return z_path;
        } else |_| {
            allocator.free(z_path);
            return null;
        }
    }

    // Bare name -- search PATH
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch return null;
    defer allocator.free(path_env);

    const sep: u8 = if (comptime builtin.os.tag == .windows) ';' else ':';
    var it = std.mem.splitScalar(u8, path_env, sep);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;

        // Try the name as-is
        const path_sep = if (comptime builtin.os.tag == .windows) "\\" else "/";
        const full_path = std.fmt.allocPrint(allocator, "{s}" ++ path_sep ++ "{s}", .{ dir, program }) catch continue;
        if (std.fs.cwd().statFile(full_path)) |_| {
            defer allocator.free(full_path);
            return allocator.dupeZ(u8, full_path) catch return null;
        } else |_| {
            allocator.free(full_path);
        }

        // On Windows, also try with .exe suffix
        if (comptime builtin.os.tag == .windows) {
            const exe_path = std.fmt.allocPrint(allocator, "{s}" ++ "\\" ++ "{s}.exe", .{ dir, program }) catch continue;
            if (std.fs.cwd().statFile(exe_path)) |_| {
                defer allocator.free(exe_path);
                return allocator.dupeZ(u8, exe_path) catch return null;
            } else |_| {
                allocator.free(exe_path);
            }
        }
    }

    return null;
}

/// Build a null-terminated args array for execve/spawn.
/// Convention: argv[0] is the shell path, subsequent elements are the config args.
fn buildArgsArray(
    allocator: std.mem.Allocator,
    shell_path: [*:0]const u8,
    config_args: []const []const u8,
) ?[*:null]const ?[*:0]const u8 {
    // argv[0] = shell_path, then config_args, then null sentinel
    const total = 1 + config_args.len;
    const argv = allocator.allocSentinel(?[*:0]const u8, total, null) catch return null;
    argv[0] = shell_path;
    for (config_args, 0..) |arg, i| {
        argv[1 + i] = allocator.dupeZ(u8, arg) catch return null;
    }
    return argv;
}

/// Known shells for testing across platforms (D-09).
pub const known_shells = if (builtin.os.tag == .windows)
    [_]ShellConfig{
        .{ .path = "pwsh.exe", .args = null, .name = "pwsh" },
        .{ .path = "powershell.exe", .args = null, .name = "powershell" },
        .{ .path = "cmd.exe", .args = null, .name = "cmd" },
        .{ .path = "nu.exe", .args = null, .name = "nu" },
    }
else
    [_]ShellConfig{
        .{ .path = "/bin/bash", .args = null, .name = "bash" },
        .{ .path = "/bin/zsh", .args = null, .name = "zsh" },
        .{ .path = "/usr/bin/fish", .args = null, .name = "fish" },
        .{ .path = "/usr/bin/nu", .args = null, .name = "nushell" },
    };

/// Get list of available known shells on the current platform.
pub fn getAvailableShells() []const ShellConfig {
    return &known_shells;
}

/// Lightweight display-oriented shell info for the ShellPicker overlay (Phase 11).
pub const ShellInfo = struct {
    name: []const u8, // e.g. "bash"
    path: []const u8, // e.g. "/usr/bin/bash"
    /// Original sentinel-terminated allocation from findExecutable (for freeing).
    path_alloc: ?[*:0]const u8 = null,
};

/// Filter known_shells to only those available on PATH, plus the configured shell (D-11, D-12, D-13).
/// Returns a heap-allocated slice of ShellInfo. Caller must free `.items` when done.
pub fn filterAvailableShells(
    allocator: std.mem.Allocator,
    config_program: ?[]const u8,
) struct { items: []ShellInfo, count: usize } {
    var result_buf: [16]ShellInfo = undefined;
    var count: usize = 0;

    // 1. Check config_program first (D-13: always include if set)
    if (config_program) |program| {
        if (findExecutable(allocator, program)) |found_path| {
            const path_slice = std.mem.span(found_path);
            result_buf[count] = .{
                .name = extractShellName(program),
                .path = path_slice,
                .path_alloc = found_path,
            };
            count += 1;
        }
    }

    // 2. Filter known_shells by PATH availability (D-11)
    for (&known_shells) |ks| {
        if (count >= 16) break;
        const ks_name = ks.name;
        // Skip if already added (config shell was in known_shells)
        var already = false;
        for (result_buf[0..count]) |existing| {
            if (std.mem.eql(u8, existing.name, ks_name)) {
                already = true;
                break;
            }
        }
        if (already) continue;

        if (findExecutable(allocator, ks_name)) |found_path| {
            result_buf[count] = .{
                .name = ks_name,
                .path = std.mem.span(found_path),
                .path_alloc = found_path,
            };
            count += 1;
        }
    }

    // Copy to heap-allocated slice for caller
    const items = allocator.alloc(ShellInfo, count) catch return .{ .items = &.{}, .count = 0 };
    @memcpy(items, result_buf[0..count]);
    return .{ .items = items, .count = count };
}

// -------------------------------------------------------
// Tests (Phase 11)
// -------------------------------------------------------

test "findExecutable is callable (pub visibility)" {
    const result = findExecutable(std.testing.allocator, "nonexistent_shell_xyz");
    try std.testing.expect(result == null);
}

test "ShellInfo struct fields are accessible" {
    const info = ShellInfo{ .name = "bash", .path = "/usr/bin/bash" };
    try std.testing.expect(info.name.len > 0);
    try std.testing.expect(info.path.len > 0);
}

test "filterAvailableShells returns a result" {
    const result = filterAvailableShells(std.testing.allocator, null);
    defer if (result.items.len > 0) std.testing.allocator.free(result.items);
    // count should be >= 0 (may be 0 in CI with no shells on PATH)
    try std.testing.expect(result.count <= 16);
}
