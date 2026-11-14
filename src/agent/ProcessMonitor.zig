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
///     shell PID, picking the agent if one is running (the outermost, not the
///     helpers it spawns), else the most-recently-started leaf. Processes not
///     on the pane's console are not "running in" the pane, nor is anything
///     they start: long-lived shell helpers (nu plugins), GUI apps started
///     from the shell (no console), and background jobs with a console of
///     their own (e.g. pwsh Start-Job, which gets its own conhost).
const std = @import("std");
const pio = @import("pio");
const builtin = @import("builtin");

pub const MAX_NAME = 64;

pub const ProcessName = struct {
    buf: [MAX_NAME]u8 = @as([MAX_NAME]u8, @splat(0)),
    len: u32 = 0,
    /// The foreground process is the shell itself (nothing running in it).
    is_shell: bool = false,
    /// A process named in `QueryInput.agent_names` is running under the shell.
    /// Null where the platform can't tell (only the foreground group is known).
    agent_running: ?bool = null,

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
    /// Agent process names to look for among all descendants (Windows).
    agent_names: []const []const u8 = &.{},
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
    if (!readProcComm(@intCast(pgid), out)) return false;
    // The shell leads its own process group; a job gets a new one.
    out.is_shell = if (in.shell_pid) |sp| sp == pgid else false;
    return true;
}

fn readProcComm(pid: i32, out: *ProcessName) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return false;
    const file = std.Io.Dir.openFileAbsolute(pio.io, path, .{}) catch return false;
    defer file.close(pio.io);
    var read_buf: [MAX_NAME + 1]u8 = undefined;
    const n = file.readStreaming(pio.io, &.{&read_buf}) catch return false;
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
    out.is_shell = if (in.shell_pid) |sp| sp == pgid else false;
    return true;
}

extern "c" fn proc_name(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;

// ── Windows ──────────────────────────────────────────────

const windows = std.os.windows;

const DWORD = windows.DWORD;
const HANDLE = windows.HANDLE;
// Win32 BOOL as a plain int (std's BOOL is now an enum); same ABI.
const BOOL = c_int;
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
const PROCESS_VM_READ: DWORD = 0x0010;

const PROCESS_BASIC_INFORMATION = extern struct {
    ExitStatus: usize = 0,
    PebBaseAddress: ?*anyopaque = null,
    AffinityMask: usize = 0,
    BasePriority: i32 = 0,
    UniqueProcessId: usize = 0,
    InheritedFromUniqueProcessId: usize = 0,
};

extern "ntdll" fn NtQueryInformationProcess(
    ProcessHandle: HANDLE,
    ProcessInformationClass: DWORD,
    ProcessInformation: *anyopaque,
    ProcessInformationLength: DWORD,
    ReturnLength: ?*DWORD,
) callconv(.winapi) i32;

extern "kernel32" fn ReadProcessMemory(
    hProcess: HANDLE,
    lpBaseAddress: ?*const anyopaque,
    lpBuffer: *anyopaque,
    nSize: usize,
    lpNumberOfBytesRead: ?*usize,
) callconv(.winapi) BOOL;

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
    var agent_idx: ?usize = null;

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
            var name = names[i][0..name_lens[i]];
            if (parent == shell_pid_u and isShellHelper(name)) continue;
            // An agent running on node / bun / deno: name it after its package.
            if (isScriptHost(name)) {
                var cl_buf: [1024]u8 = undefined;
                if (readCommandLine(pids[i], &cl_buf)) |cl| if (scriptAgent(cl)) |agent| {
                    @memcpy(names[i][0..agent.len], agent);
                    name_lens[i] = @intCast(agent.len);
                    name = names[i][0..agent.len];
                };
            }
            if (pids[i] != shell_pid_u and !onPaneConsole(pids[i], pids[0..count], ppids[0..count], names[0..count], name_lens[0..count])) continue;
            // Enqueue this descendant
            if (qtail < queue.len) {
                queue[qtail] = pids[i];
                qtail += 1;
            }
            // Consider as candidate (exclude the shell itself)
            if (pids[i] == shell_pid_u) continue;
            // Breadth-first, so the first match is the outermost agent.
            if (agent_idx == null and nameMatchesList(name, in.agent_names)) agent_idx = i;
            const ctime = getProcessCreationTime(pids[i]);
            if (ctime == 0) continue;
            if (best_idx == null or ctime > best_ctime) {
                best_idx = i;
                best_ctime = ctime;
            }
        }
    }

    out.agent_running = agent_idx != null;
    if (agent_idx orelse best_idx) |idx| {
        out.set(names[idx][0..name_lens[idx]]);
        out.is_shell = false;
        return true;
    }
    // No descendant — fall back to shell's own name
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (pids[i] == shell_pid_u) {
            out.set(names[i][0..name_lens[i]]);
            out.is_shell = true;
            return true;
        }
    }
    return false;
}

/// Whether `pid` shares the pane's console. A process with its own console
/// has that console's conhost as a child; a GUI or detached process has no
/// console at all. Unknown (access denied) counts as on the console.
fn onPaneConsole(pid: DWORD, pids: []const DWORD, ppids: []const DWORD, names: []const [32]u8, name_lens: []const u32) bool {
    for (pids, ppids, names, name_lens) |p, pp, *n, len| {
        _ = p;
        if (pp != pid) continue;
        if (isConsoleHost(n[0..len])) return false;
    }
    return hasConsole(pid) orelse true;
}

fn isConsoleHost(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "conhost") or std.ascii.eqlIgnoreCase(name, "OpenConsole");
}

/// ProcessParameters->ConsoleHandle is null for GUI and detached processes.
/// Null when it can't be read (other bitness, access denied).
fn hasConsole(pid: DWORD) ?bool {
    if (@sizeOf(usize) != 8) return null;
    const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, 0, pid) orelse return null;
    defer _ = CloseHandle(h);
    var pbi: PROCESS_BASIC_INFORMATION = .{};
    if (NtQueryInformationProcess(h, 0, &pbi, @sizeOf(PROCESS_BASIC_INFORMATION), null) != 0) return null;
    const peb = @intFromPtr(pbi.PebBaseAddress orelse return null);
    var params: usize = 0;
    if (ReadProcessMemory(h, @ptrFromInt(peb + 0x20), @ptrCast(&params), @sizeOf(usize), null) == 0 or params == 0) return null;
    var console: usize = 0;
    if (ReadProcessMemory(h, @ptrFromInt(params + 0x10), @ptrCast(&console), @sizeOf(usize), null) == 0) return null;
    return console != 0;
}

/// The process's command line (ProcessParameters->CommandLine), non-ASCII
/// as '?', truncated to `buf`. Null when it can't be read.
fn readCommandLine(pid: DWORD, buf: []u8) ?[]const u8 {
    if (@sizeOf(usize) != 8) return null;
    const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, 0, pid) orelse return null;
    defer _ = CloseHandle(h);
    var pbi: PROCESS_BASIC_INFORMATION = .{};
    if (NtQueryInformationProcess(h, 0, &pbi, @sizeOf(PROCESS_BASIC_INFORMATION), null) != 0) return null;
    const peb = @intFromPtr(pbi.PebBaseAddress orelse return null);
    var params: usize = 0;
    if (ReadProcessMemory(h, @ptrFromInt(peb + 0x20), @ptrCast(&params), @sizeOf(usize), null) == 0 or params == 0) return null;
    // UNICODE_STRING CommandLine at 0x70: Length (bytes), MaximumLength, Buffer at 0x78.
    var len_bytes: u16 = 0;
    if (ReadProcessMemory(h, @ptrFromInt(params + 0x70), @ptrCast(&len_bytes), 2, null) == 0) return null;
    var str_ptr: usize = 0;
    if (ReadProcessMemory(h, @ptrFromInt(params + 0x78), @ptrCast(&str_ptr), @sizeOf(usize), null) == 0 or str_ptr == 0) return null;
    var wide: [1024]u16 = undefined;
    const units = @min(@as(usize, len_bytes / 2), wide.len, buf.len);
    if (units == 0) return null;
    if (ReadProcessMemory(h, @ptrFromInt(str_ptr), @ptrCast(&wide), units * 2, null) == 0) return null;
    for (wide[0..units], 0..) |u, k| buf[k] = if (u < 0x80) @intCast(u) else '?';
    return buf[0..units];
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

/// Agents that run on a script host, by npm package (scope dropped), and the
/// name they go by in `agent.processes`.
const script_agents = [_]struct { pkg: []const u8, name: []const u8 }{
    .{ .pkg = "pi-coding-agent", .name = "pi" },
    .{ .pkg = "claude-code", .name = "claude" },
    .{ .pkg = "codex", .name = "codex" },
    .{ .pkg = "opencode-ai", .name = "opencode" },
};

fn isScriptHost(name: []const u8) bool {
    for ([_][]const u8{ "node", "bun", "deno" }) |host| {
        if (std.ascii.eqlIgnoreCase(name, host)) return true;
    }
    return false;
}

/// The npm package that owns the script in a command line:
/// `node C:\…\node_modules\@scope\pkg\dist\cli.js` gives "pkg".
fn scriptPackage(cmdline: []const u8) ?[]const u8 {
    const marker = "node_modules";
    var start: usize = undefined;
    var found = false;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, cmdline, i, marker)) |at| : (i = at + 1) {
        const after = at + marker.len;
        if (after < cmdline.len and (cmdline[after] == '/' or cmdline[after] == '\\')) {
            start = after + 1;
            found = true;
        }
    }
    if (!found) return null;
    var rest = cmdline[start..];
    if (rest.len > 0 and rest[0] == '@') {
        const sep = std.mem.indexOfAny(u8, rest, "/\\") orelse return null;
        rest = rest[sep + 1 ..];
    }
    const end = std.mem.indexOfAny(u8, rest, "/\\\" ") orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

/// The agent name for a script-host command line, if it runs a known agent.
fn scriptAgent(cmdline: []const u8) ?[]const u8 {
    const pkg = scriptPackage(cmdline) orelse return null;
    for (script_agents) |a| {
        if (std.ascii.eqlIgnoreCase(pkg, a.pkg)) return a.name;
    }
    return null;
}

test "scriptAgent maps agent packages run by node" {
    try std.testing.expectEqualStrings("pi", scriptAgent(
        "\"C:\\nodejs\\node.exe\" \"C:\\nodejs\\node_modules\\@earendil-works\\pi-coding-agent\\dist\\bundle\\cli.js\"",
    ).?);
    try std.testing.expectEqualStrings("claude", scriptAgent("node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js").?);
    try std.testing.expectEqualStrings("opencode", scriptAgent("bun /x/node_modules/opencode-ai/bin/opencode").?);
    try std.testing.expect(scriptAgent("node server.js") == null);
    try std.testing.expect(scriptAgent("node /x/node_modules/typescript/bin/tsc") == null);
    try std.testing.expect(scriptAgent("node /x/node_modules/") == null);
}

/// A child the shell keeps alive for itself rather than a command the user
/// ran: nushell starts plugins from its prompt (e.g. nu_plugin_gstat in a git
/// folder) and leaves them running for a while afterwards.
fn isShellHelper(name: []const u8) bool {
    const prefix = "nu_plugin_";
    return name.len >= prefix.len and std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix);
}

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

test "isShellHelper matches nushell plugins only" {
    try std.testing.expect(isShellHelper("nu_plugin_gstat"));
    try std.testing.expect(isShellHelper("NU_PLUGIN_query"));
    try std.testing.expect(!isShellHelper("nu"));
    try std.testing.expect(!isShellHelper("claude"));
    try std.testing.expect(!isShellHelper("nu_plugin"));
}
