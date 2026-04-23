/// Foreground-process detection for a PTY.
///
/// Given a shell PID (the direct child of the PTY), returns the name of the
/// process the user is actually interacting with — e.g. if the shell launched
/// `claude`, this returns "claude" rather than "bash".
///
/// Strategy per platform:
///   - POSIX: `tcgetpgrp(master_fd)` returns the foreground process group id;
///     read the pgid's comm from /proc on Linux, or fall back to the shell
///     name on failure (macOS: TODO — use proc_pidpath when needed).
///   - Windows: ConPTY has no foreground-process API, so we snapshot the full
///     process list via CreateToolhelp32Snapshot and walk descendants of the
///     shell PID, picking the most-recently-started leaf.
const std = @import("std");
const builtin = @import("builtin");

pub const MAX_NAME = 64;

pub const ProcessName = struct {
    buf: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    len: u32 = 0,

    pub fn slice(self: *const ProcessName) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *ProcessName, name: []const u8) void {
        const n = @min(name.len, MAX_NAME);
        @memset(&self.buf, 0);
        @memcpy(self.buf[0..n], name[0..n]);
        self.len = @intCast(n);
    }
};

pub const QueryInput = struct {
    /// Direct child PID of the PTY (the shell).
    shell_pid: ?i32,
    /// PTY master fd (POSIX only; ignored on Windows).
    master_fd: c_int = -1,
};

/// Query the foreground process name. Writes into `out` and returns true on
/// success. On failure leaves `out` untouched and returns false.
pub fn queryForegroundName(in: QueryInput, out: *ProcessName) bool {
    return switch (builtin.os.tag) {
        .linux => queryLinux(in, out),
        .macos => queryMacos(in, out),
        .windows => queryWindows(in, out),
        else => false,
    };
}

// ── Linux ────────────────────────────────────────────────

extern "c" fn tcgetpgrp(fd: c_int) c_int;

fn queryLinux(in: QueryInput, out: *ProcessName) bool {
    if (in.master_fd < 0) return false;
    const pgid = tcgetpgrp(in.master_fd);
    if (pgid <= 0) return false;
    return readProcComm(@intCast(pgid), out);
}

fn readProcComm(pid: i32, out: *ProcessName) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return false;
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();
    var read_buf: [MAX_NAME + 1]u8 = undefined;
    const n = file.read(&read_buf) catch return false;
    // Strip trailing newline
    var end = n;
    while (end > 0 and (read_buf[end - 1] == '\n' or read_buf[end - 1] == 0)) : (end -= 1) {}
    if (end == 0) return false;
    out.set(read_buf[0..end]);
    return true;
}

// ── macOS ────────────────────────────────────────────────

fn queryMacos(in: QueryInput, out: *ProcessName) bool {
    if (in.master_fd < 0) return false;
    const pgid = tcgetpgrp(in.master_fd);
    if (pgid <= 0) return false;
    // libproc proc_name
    var name_buf: [MAX_NAME]u8 = undefined;
    const rc = proc_name(pgid, &name_buf, @intCast(name_buf.len));
    if (rc <= 0) return false;
    const n: usize = @intCast(rc);
    out.set(name_buf[0..@min(n, MAX_NAME)]);
    return true;
}

extern "c" fn proc_name(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;

// ── Windows ──────────────────────────────────────────────

const windows = std.os.windows;

const DWORD = windows.DWORD;
const HANDLE = windows.HANDLE;
const BOOL = windows.BOOL;
const FILETIME = extern struct { low: DWORD, high: DWORD };

const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const TH32CS_SNAPPROCESS: DWORD = 0x00000002;

const PROCESSENTRY32W = extern struct {
    dwSize: DWORD,
    cntUsage: DWORD,
    th32ProcessID: DWORD,
    th32DefaultHeapID: usize,
    th32ModuleID: DWORD,
    cntThreads: DWORD,
    th32ParentProcessID: DWORD,
    pcPriClassBase: i32,
    dwFlags: DWORD,
    szExeFile: [260]u16,
};

extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn Process32FirstW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
extern "kernel32" fn Process32NextW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetProcessTimes(
    hProcess: HANDLE,
    lpCreationTime: *FILETIME,
    lpExitTime: *FILETIME,
    lpKernelTime: *FILETIME,
    lpUserTime: *FILETIME,
) callconv(.winapi) BOOL;

const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;

fn queryWindows(in: QueryInput, out: *ProcessName) bool {
    const shell_pid = in.shell_pid orelse return false;
    if (shell_pid <= 0) return false;

    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return false;
    defer _ = CloseHandle(snap);

    // Collect all processes
    const MAX_PROCS = 2048;
    var pids: [MAX_PROCS]DWORD = undefined;
    var ppids: [MAX_PROCS]DWORD = undefined;
    var names: [MAX_PROCS][32]u8 = undefined;
    var name_lens: [MAX_PROCS]u32 = undefined;
    var count: usize = 0;

    var entry: PROCESSENTRY32W = undefined;
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(snap, &entry) == 0) return false;
    while (true) {
        if (count >= MAX_PROCS) break;
        pids[count] = entry.th32ProcessID;
        ppids[count] = entry.th32ParentProcessID;
        // szExeFile is UTF-16 sentinel-terminated; downconvert each unit to a
        // single byte (replace non-ASCII with '?'). Process names we match
        // against are ASCII (claude, codex, ...), so this is sufficient and
        // sidesteps surrogate-pair edge cases that crash std.unicode.
        var ascii_buf: [32]u8 = undefined;
        var alen: usize = 0;
        var wi: usize = 0;
        while (wi < entry.szExeFile.len and entry.szExeFile[wi] != 0 and alen < ascii_buf.len) : (wi += 1) {
            const u = entry.szExeFile[wi];
            ascii_buf[alen] = if (u < 0x80) @intCast(u) else '?';
            alen += 1;
        }
        var effective = alen;
        if (effective >= 4 and std.ascii.eqlIgnoreCase(ascii_buf[effective - 4 .. effective], ".exe")) {
            effective -= 4;
        }
        @memcpy(names[count][0..effective], ascii_buf[0..effective]);
        name_lens[count] = @intCast(effective);
        count += 1;
        if (Process32NextW(snap, &entry) == 0) break;
    }

    // Walk descendants of shell_pid via BFS; track most-recently-started descendant.
    const shell_pid_u: DWORD = @intCast(shell_pid);

    var best_idx: ?usize = null;
    var best_ctime: u64 = 0;

    // Mark queue of pids to traverse
    var queue: [256]DWORD = undefined;
    var qhead: usize = 0;
    var qtail: usize = 0;
    queue[qtail] = shell_pid_u;
    qtail += 1;

    while (qhead < qtail) : (qhead += 1) {
        const parent = queue[qhead];
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (ppids[i] != parent) continue;
            // Enqueue this descendant
            if (qtail < queue.len) {
                queue[qtail] = pids[i];
                qtail += 1;
            }
            // Consider as candidate (exclude the shell itself)
            if (pids[i] == shell_pid_u) continue;
            const ctime = getProcessCreationTime(pids[i]);
            if (ctime == 0) continue;
            if (best_idx == null or ctime > best_ctime) {
                best_idx = i;
                best_ctime = ctime;
            }
        }
    }

    if (best_idx) |idx| {
        out.set(names[idx][0..name_lens[idx]]);
        return true;
    }
    // No descendant — fall back to shell's own name
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (pids[i] == shell_pid_u) {
            out.set(names[i][0..name_lens[i]]);
            return true;
        }
    }
    return false;
}

fn getProcessCreationTime(pid: DWORD) u64 {
    const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return 0;
    defer _ = CloseHandle(h);
    var ct: FILETIME = undefined;
    var et: FILETIME = undefined;
    var kt: FILETIME = undefined;
    var ut: FILETIME = undefined;
    if (GetProcessTimes(h, &ct, &et, &kt, &ut) == 0) return 0;
    return (@as(u64, ct.high) << 32) | @as(u64, ct.low);
}

// ── Helpers ──────────────────────────────────────────────

/// Case-insensitive match of `name` against any entry in `list`.
pub fn nameMatchesList(name: []const u8, list: []const []const u8) bool {
    for (list) |entry| {
        if (entry.len != name.len) continue;
        if (std.ascii.eqlIgnoreCase(entry, name)) return true;
    }
    return false;
}

// ── Tests ────────────────────────────────────────────────

test "ProcessName set/slice" {
    var pn = ProcessName{};
    pn.set("claude");
    try std.testing.expectEqualStrings("claude", pn.slice());
    pn.set("codex");
    try std.testing.expectEqualStrings("codex", pn.slice());
}

test "nameMatchesList case-insensitive" {
    const list = [_][]const u8{ "claude", "opencode", "codex" };
    try std.testing.expect(nameMatchesList("claude", &list));
    try std.testing.expect(nameMatchesList("CLAUDE", &list));
    try std.testing.expect(nameMatchesList("Codex", &list));
    try std.testing.expect(!nameMatchesList("bash", &list));
    try std.testing.expect(!nameMatchesList("claude-code", &list));
}
