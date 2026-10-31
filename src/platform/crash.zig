//! Crash handling: catches Zig panics and Windows native exceptions,
//! writes a log + minidump to %LOCALAPPDATA%\pterm\crashes\ before terminating.
//!
//! Usage in main.zig (root scope):
//!   const crash = @import("crash");
//!   pub const panic = std.debug.FullPanic(crash.panicHandler);
//!   pub fn main() !void {
//!       crash.install();
//!       ...
//!   }

const std = @import("std");
const pio = @import("pio");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const windows = std.os.windows;

// --- Windows extern declarations ---------------------------------------------
const HANDLE = windows.HANDLE;
const HMODULE = windows.HMODULE;
const DWORD = windows.DWORD;
// Win32 BOOL as a plain int (std's BOOL is now an enum); same ABI.
const BOOL = c_int;
const LONG = c_long;
const LPVOID = ?*anyopaque;

const EXCEPTION_POINTERS = windows.EXCEPTION_POINTERS;
const TopLevelExceptionFilter = *const fn (*EXCEPTION_POINTERS) callconv(.winapi) LONG;

const EXCEPTION_EXECUTE_HANDLER: LONG = 1;

const MINIDUMP_EXCEPTION_INFORMATION = extern struct {
    ThreadId: DWORD,
    ExceptionPointers: *EXCEPTION_POINTERS,
    ClientPointers: BOOL,
};

// MiniDumpNormal — basic stack walk + thread context. Small, reliable.
const MINIDUMP_TYPE: DWORD = 0x0000;

const MiniDumpWriteDumpFn = *const fn (
    HANDLE,
    DWORD,
    HANDLE,
    DWORD,
    ?*MINIDUMP_EXCEPTION_INFORMATION,
    ?*anyopaque,
    ?*anyopaque,
) callconv(.winapi) BOOL;

extern "kernel32" fn SetUnhandledExceptionFilter(
    filter: ?TopLevelExceptionFilter,
) callconv(.winapi) ?TopLevelExceptionFilter;
extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;

const GENERIC_READ: DWORD = 0x80000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const CREATE_ALWAYS: DWORD = 2;
const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

// --- Public API --------------------------------------------------------------

/// Install the OS-level unhandled exception handler. Call once at the start
/// of main (after the panic handler is set via FullPanic).
pub fn install() void {
    if (is_windows) {
        _ = SetUnhandledExceptionFilter(sehFilter);
    }
}

/// Wire this into root scope:
///     pub const panic = std.debug.FullPanic(crash.panicHandler);
pub fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);

    // Reentry guard — if writing the dump itself panics, fall through to default.
    if (panicking.swap(true, .seq_cst)) {
        std.debug.defaultPanic(msg, first_trace_addr);
    }

    writePanicLog(msg, first_trace_addr orelse @returnAddress()) catch {};

    // Hand off to default for stderr output + abort. This ensures the process
    // actually terminates and that developers running with a console see the
    // trace too.
    std.debug.defaultPanic(msg, first_trace_addr);
}

var panicking = std.atomic.Value(bool).init(false);

// --- Internals ---------------------------------------------------------------

/// Resolve crash directory into `buf` and ensure it exists. Returns the path slice.
fn resolveCrashDir(buf: []u8) ![]const u8 {
    var env_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&env_buf);

    const path = if (is_windows) blk: {
        const local = pio.getEnvVarOwned(fba.allocator(), "LOCALAPPDATA") catch
            return error.NoCrashDir;
        break :blk try std.fmt.bufPrint(buf, "{s}\\pterm\\crashes", .{local});
    } else if (builtin.os.tag == .macos) blk: {
        const home = pio.getEnvVarOwned(fba.allocator(), "HOME") catch
            return error.NoCrashDir;
        break :blk try std.fmt.bufPrint(buf, "{s}/Library/Logs/pterm", .{home});
    } else blk: {
        const home = pio.getEnvVarOwned(fba.allocator(), "HOME") catch
            return error.NoCrashDir;
        break :blk try std.fmt.bufPrint(buf, "{s}/.local/state/pterm/crashes", .{home});
    };

    std.Io.Dir.cwd().createDirPath(pio.io, path) catch {};
    return path;
}

/// Build a unique filename stem `crash-YYYYMMDD-HHMMSS-<pid>` into `buf`.
fn buildStem(buf: []u8) ![]const u8 {
    const epoch_secs: u64 = @intCast(pio.timestamp());
    const day_secs = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day = day_secs.getEpochDay();
    const ymd = day.calculateYearDay();
    const md = ymd.calculateMonthDay();
    const tod = day_secs.getDaySeconds();
    const pid: u32 = if (is_windows) GetCurrentProcessId() else @intCast(std.os.linux.getpid());
    return try std.fmt.bufPrint(
        buf,
        "crash-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{d}",
        .{
            ymd.year,
            md.month.numeric(),
            md.day_index + 1,
            tod.getHoursIntoDay(),
            tod.getMinutesIntoHour(),
            tod.getSecondsIntoMinute(),
            pid,
        },
    );
}

fn writePanicLog(msg: []const u8, first_trace_addr: usize) !void {
    var dir_buf: [1024]u8 = undefined;
    const dir = try resolveCrashDir(&dir_buf);

    var stem_buf: [128]u8 = undefined;
    const stem = try buildStem(&stem_buf);

    var path_buf: [1200]u8 = undefined;
    const sep: u8 = if (is_windows) '\\' else '/';
    const path = try std.fmt.bufPrint(&path_buf, "{s}{c}{s}.log", .{ dir, sep, stem });

    const file = std.Io.Dir.cwd().createFile(pio.io, path, .{}) catch return;
    defer file.close(pio.io);

    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(pio.io, &write_buf);
    const w = &fw.interface;

    w.print("pterm panic\n", .{}) catch {};
    w.print("message: {s}\n", .{msg}) catch {};
    w.print("os: {s}-{s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) }) catch {};
    w.print("mode: {s}\n", .{@tagName(builtin.mode)}) catch {};
    if (is_windows) {
        w.print("thread: {d}\n", .{GetCurrentThreadId()}) catch {};
        w.print("pid: {d}\n", .{GetCurrentProcessId()}) catch {};
    }
    w.print("\n--- stack trace ---\n", .{}) catch {};
    var addr_buf: [64]usize = undefined;
    const trace = std.debug.captureCurrentStackTrace(.{ .first_address = first_trace_addr }, &addr_buf);
    std.debug.writeStackTrace(&trace, .{ .writer = w, .mode = .no_color }) catch {};

    fw.end() catch {};
}

/// Windows SEH unhandled exception filter. Writes a log + minidump and lets
/// the default handler terminate the process.
fn sehFilter(info: *EXCEPTION_POINTERS) callconv(.winapi) LONG {
    if (panicking.swap(true, .seq_cst)) return EXCEPTION_EXECUTE_HANDLER;

    var dir_buf: [1024]u8 = undefined;
    const dir = resolveCrashDir(&dir_buf) catch return EXCEPTION_EXECUTE_HANDLER;

    var stem_buf: [128]u8 = undefined;
    const stem = buildStem(&stem_buf) catch return EXCEPTION_EXECUTE_HANDLER;

    // Open the log first so we can write minidump diagnostics into it too.
    var log_path_buf: [1200]u8 = undefined;
    const log_path = std.fmt.bufPrint(&log_path_buf, "{s}\\{s}.log", .{ dir, stem }) catch
        return EXCEPTION_EXECUTE_HANDLER;
    const log_file = std.Io.Dir.cwd().createFile(pio.io, log_path, .{}) catch
        return EXCEPTION_EXECUTE_HANDLER;
    defer log_file.close(pio.io);

    var write_buf: [4096]u8 = undefined;
    var fw = log_file.writer(pio.io, &write_buf);
    const w = &fw.interface;

    const rec = info.ExceptionRecord;
    w.print("pterm native crash (Windows SEH)\n", .{}) catch {};
    w.print("exception code: 0x{X:0>8} ({s})\n", .{ rec.ExceptionCode, codeName(rec.ExceptionCode) }) catch {};
    w.print("exception address: 0x{X}\n", .{@intFromPtr(rec.ExceptionAddress)}) catch {};
    w.print("os: {s}-{s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) }) catch {};
    w.print("mode: {s}\n", .{@tagName(builtin.mode)}) catch {};
    w.print("thread: {d}\n", .{GetCurrentThreadId()}) catch {};
    w.print("pid: {d}\n", .{GetCurrentProcessId()}) catch {};

    writeMinidump(dir, stem, info, w) catch |e| {
        w.print("minidump: error {s}\n", .{@errorName(e)}) catch {};
    };

    fw.end() catch {};
    return EXCEPTION_EXECUTE_HANDLER;
}

fn writeMinidump(
    dir: []const u8,
    stem: []const u8,
    info: *EXCEPTION_POINTERS,
    log: *std.Io.Writer,
) !void {
    // Resolve MiniDumpWriteDump dynamically so we don't add a link-time dep on DbgHelp.
    const dbghelp_name = std.unicode.utf8ToUtf16LeStringLiteral("DbgHelp.dll");
    const module = LoadLibraryW(dbghelp_name) orelse return error.NoDbgHelp;
    const proc = GetProcAddress(module, "MiniDumpWriteDump") orelse return error.NoMiniDumpWriteDump;
    const minidump_write: MiniDumpWriteDumpFn = @ptrCast(@alignCast(proc));

    var path_buf: [1200]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}\\{s}.dmp", .{ dir, stem });

    // Use raw CreateFileW: MiniDumpWriteDump needs GENERIC_WRITE on a synchronous
    // handle. Zig's File API opens via NtCreateFile and produces handles that
    // MiniDumpWriteDump rejects with ERROR_NOACCESS on some setups.
    var path_w_buf: [1024]u16 = undefined;
    const path_w_len = std.unicode.utf8ToUtf16Le(&path_w_buf, path) catch return error.PathConvert;
    if (path_w_len >= path_w_buf.len) return error.PathTooLong;
    path_w_buf[path_w_len] = 0;

    const file_handle = CreateFileW(
        @ptrCast(&path_w_buf),
        GENERIC_READ | GENERIC_WRITE,
        0,
        null,
        CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (file_handle == INVALID_HANDLE_VALUE) return error.CreateFailed;
    defer _ = CloseHandle(file_handle);

    // NOTE: ExceptionParam is intentionally null. Passing
    // MINIDUMP_EXCEPTION_INFORMATION pointing at our own thread's
    // EXCEPTION_POINTERS makes MiniDumpWriteDump return ERROR_NOACCESS on
    // some Windows builds (a known DbgHelp quirk for in-process self-dumps).
    // The .log captures the exception code/address explicitly, and the dump
    // still includes full thread contexts for debugger inspection.
    _ = info;
    const ok = minidump_write(
        GetCurrentProcess(),
        GetCurrentProcessId(),
        file_handle,
        MINIDUMP_TYPE,
        null,
        null,
        null,
    );
    if (ok == 0) {
        const err = GetLastError();
        log.print("minidump: MiniDumpWriteDump failed, GetLastError=0x{X:0>8}\n", .{err}) catch {};
        return error.MiniDumpFailed;
    }
    log.print("minidump: written to {s}\n", .{path}) catch {};
}

fn codeName(code: u32) []const u8 {
    return switch (code) {
        0xC0000005 => "ACCESS_VIOLATION",
        0xC0000094 => "INTEGER_DIVIDE_BY_ZERO",
        0xC0000095 => "INTEGER_OVERFLOW",
        0xC00000FD => "STACK_OVERFLOW",
        0xC0000409 => "STACK_BUFFER_OVERRUN",
        0x80000003 => "BREAKPOINT",
        0xC000001D => "ILLEGAL_INSTRUCTION",
        0xC0000006 => "IN_PAGE_ERROR",
        0xC000008C => "ARRAY_BOUNDS_EXCEEDED",
        0xC0000025 => "NONCONTINUABLE_EXCEPTION",
        else => "UNKNOWN",
    };
}
