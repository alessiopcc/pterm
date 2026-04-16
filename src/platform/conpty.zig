// Windows ConPTY Backend
//
// CRITICAL: ConPTY Deadlock Risk (Pitfall 2)
// ==========================================
// Microsoft explicitly warns: "Servicing all pseudoconsole activities on the
// same thread may result in a deadlock." ConPTY's internal buffers are fixed-size.
// The output pipe MUST be drained on a separate thread from the input pipe.
// Failure to do so will cause hangs during heavy output (e.g., `dir /s`).
//
// This backend provides read() and write() methods that are safe to call from
// separate threads. The PtyReader (src/termio/reader.zig) handles the read
// thread, while writes happen from the main/input thread.
//
// References:
// - https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session
// - https://learn.microsoft.com/en-us/windows/console/createpseudoconsole

const std = @import("std");
const windows = std.os.windows;

const HANDLE = windows.HANDLE;
const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const HRESULT = windows.HRESULT;

const COORD = extern struct {
    X: i16,
    Y: i16,
};

const HPCON = HANDLE;

const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD = @sizeOf(SECURITY_ATTRIBUTES),
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: BOOL = 0,
};

const STARTUPINFOW = extern struct {
    cb: DWORD = @sizeOf(STARTUPINFOW),
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW = .{},
    lpAttributeList: ?LPPROC_THREAD_ATTRIBUTE_LIST = null,
};

const LPPROC_THREAD_ATTRIBUTE_LIST = *anyopaque;

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE = INVALID_HANDLE_VALUE,
    hThread: HANDLE = INVALID_HANDLE_VALUE,
    dwProcessId: DWORD = 0,
    dwThreadId: DWORD = 0,
};

// ConPTY API imports
extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: HANDLE,
    hOutput: HANDLE,
    dwFlags: DWORD,
    phPC: *HPCON,
) callconv(.c) HRESULT;

extern "kernel32" fn ResizePseudoConsole(
    hPC: HPCON,
    size: COORD,
) callconv(.c) HRESULT;

extern "kernel32" fn ClosePseudoConsole(
    hPC: HPCON,
) callconv(.c) void;

extern "kernel32" fn CreatePipe(
    hReadPipe: *HANDLE,
    hWritePipe: *HANDLE,
    lpPipeAttributes: ?*const SECURITY_ATTRIBUTES,
    nSize: DWORD,
) callconv(.c) BOOL;

extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?LPPROC_THREAD_ATTRIBUTE_LIST,
    dwAttributeCount: DWORD,
    dwFlags: DWORD,
    lpSize: *usize,
) callconv(.c) BOOL;

extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
    dwFlags: DWORD,
    attribute: usize,
    lpValue: ?*const anyopaque,
    cbSize: usize,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*usize,
) callconv(.c) BOOL;

extern "kernel32" fn DeleteProcThreadAttributeList(
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
) callconv(.c) void;

extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*const SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*const SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *STARTUPINFOEXW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.c) BOOL;

extern "kernel32" fn TerminateProcess(
    hProcess: HANDLE,
    uExitCode: DWORD,
) callconv(.c) BOOL;

extern "kernel32" fn CloseHandle(
    hObject: HANDLE,
) callconv(.c) BOOL;

extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.c) BOOL;

extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.c) BOOL;

extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: HANDLE,
    lpBuffer: ?[*]u8,
    nBufferSize: DWORD,
    lpBytesRead: ?*DWORD,
    lpTotalBytesAvail: ?*DWORD,
    lpBytesLeftThisMessage: ?*DWORD,
) callconv(.c) BOOL;

extern "kernel32" fn WaitForSingleObject(
    hHandle: HANDLE,
    dwMilliseconds: DWORD,
) callconv(.c) DWORD;

extern "kernel32" fn GetLastError() callconv(.c) DWORD;

extern "kernel32" fn SetEnvironmentVariableA(
    lpName: [*:0]const u8,
    lpValue: [*:0]const u8,
) callconv(.c) BOOL;

// NtQueryInformationProcess + ReadProcessMemory for querying child CWD
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
) callconv(.c) i32;

extern "kernel32" fn ReadProcessMemory(
    hProcess: HANDLE,
    lpBaseAddress: ?*const anyopaque,
    lpBuffer: *anyopaque,
    nSize: usize,
    lpNumberOfBytesRead: ?*usize,
) callconv(.c) BOOL;

const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;

pub const ConPtyError = error{
    CreatePipeFailed,
    CreatePseudoConsoleFailed,
    InitAttributeListFailed,
    UpdateAttributeFailed,
    CreateProcessFailed,
    ResizeFailed,
    ReadFailed,
    WriteFailed,
    AllocFailed,
};

/// Windows ConPTY pseudo-terminal backend.
pub const ConPty = struct {
    hpc: HPCON,
    /// Write to this handle to send input to the child process.
    input_write: HANDLE,
    /// Read from this handle to receive output from the child process.
    output_read: HANDLE,
    process_info: PROCESS_INFORMATION,
    attribute_list_buf: ?[]u8,
    allocator: std.mem.Allocator,
    config: @import("pty.zig").PtyConfig,

    pub fn init(allocator: std.mem.Allocator, config: @import("pty.zig").PtyConfig) ConPtyError!ConPty {
        // Create pipe pairs for ConPTY I/O
        var input_read: HANDLE = INVALID_HANDLE_VALUE;
        var input_write: HANDLE = INVALID_HANDLE_VALUE;
        var output_read: HANDLE = INVALID_HANDLE_VALUE;
        var output_write: HANDLE = INVALID_HANDLE_VALUE;

        if (CreatePipe(&input_read, &input_write, null, 0) == 0) {
            return ConPtyError.CreatePipeFailed;
        }
        errdefer {
            _ = CloseHandle(input_read);
            _ = CloseHandle(input_write);
        }

        if (CreatePipe(&output_read, &output_write, null, 0) == 0) {
            return ConPtyError.CreatePipeFailed;
        }
        errdefer {
            _ = CloseHandle(output_read);
            _ = CloseHandle(output_write);
        }

        // Create the pseudo console
        const size = COORD{
            .X = @intCast(config.cols),
            .Y = @intCast(config.rows),
        };

        var hpc: HPCON = INVALID_HANDLE_VALUE;
        const hr = CreatePseudoConsole(size, input_read, output_write, 0, &hpc);
        if (hr < 0) {
            return ConPtyError.CreatePseudoConsoleFailed;
        }

        // Close the pipe ends given to ConPTY -- we keep only our ends.
        _ = CloseHandle(input_read);
        _ = CloseHandle(output_write);

        return ConPty{
            .hpc = hpc,
            .input_write = input_write,
            .output_read = output_read,
            .process_info = .{},
            .attribute_list_buf = null,
            .allocator = allocator,
            .config = config,
        };
    }

    /// Spawn a child process attached to the ConPTY.
    pub fn spawn(self: *ConPty, shell_path: [*:0]const u8, args: ?[*:null]const ?[*:0]const u8, working_dir: ?[*:0]const u8) ConPtyError!void {
        // Convert shell path from UTF-8 to UTF-16 for CreateProcessW
        var cmd_line_buf: [2048]u16 = undefined;
        const shell_slice = std.mem.span(shell_path);
        var pos: usize = std.unicode.utf8ToUtf16Le(&cmd_line_buf, shell_slice) catch return ConPtyError.CreateProcessFailed;
        // Append args if present
        if (args) |arg_list| {
            var i: usize = 0;
            while (arg_list[i]) |arg| : (i += 1) {
                if (i == 0) continue; // skip argv[0] (shell path already written)
                if (pos >= cmd_line_buf.len - 1) break; // prevent overflow
                cmd_line_buf[pos] = ' ';
                pos += 1;
                const arg_slice = std.mem.span(arg);
                const written = std.unicode.utf8ToUtf16Le(cmd_line_buf[pos..], arg_slice) catch break;
                pos += written;
            }
        }
        cmd_line_buf[pos] = 0;
        const cmd_line: [*:0]u16 = cmd_line_buf[0..pos :0];

        // Initialize thread attribute list with ConPTY attribute
        var attr_list_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size);

        const attr_buf = self.allocator.alloc(u8, attr_list_size) catch return ConPtyError.AllocFailed;
        errdefer self.allocator.free(attr_buf);
        self.attribute_list_buf = attr_buf;

        const attr_list: LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast(attr_buf.ptr);

        if (InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_list_size) == 0) {
            return ConPtyError.InitAttributeListFailed;
        }

        // CRITICAL: Pass the HPCON value directly (it is itself a handle/pointer),
        // NOT a pointer to it. Passing &self.hpc would give ConPTY the wrong value.
        if (UpdateProcThreadAttribute(
            attr_list,
            0,
            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            self.hpc,
            @sizeOf(HPCON),
            null,
            null,
        ) == 0) {
            return ConPtyError.UpdateAttributeFailed;
        }

        // Set TERM and COLORTERM for proper terminal capability detection.
        // These are set in the parent process env and inherited by the child
        // via lpEnvironment=null in CreateProcessW.
        _ = SetEnvironmentVariableA("TERM", "xterm-256color");
        _ = SetEnvironmentVariableA("COLORTERM", "truecolor");

        // Convert working directory from UTF-8 to UTF-16 if specified
        var wd_buf: [1024]u16 = undefined;
        const wd_ptr: ?[*:0]const u16 = if (working_dir) |wd| blk: {
            const wd_slice = std.mem.span(wd);
            const wd_len = std.unicode.utf8ToUtf16Le(&wd_buf, wd_slice) catch break :blk null;
            wd_buf[wd_len] = 0;
            break :blk wd_buf[0..wd_len :0];
        } else null;

        var startup_info = STARTUPINFOEXW{
            .StartupInfo = .{ .cb = @sizeOf(STARTUPINFOEXW) },
            .lpAttributeList = attr_list,
        };

        var proc_info = PROCESS_INFORMATION{};

        if (CreateProcessW(
            null,
            cmd_line,
            null,
            null,
            0, // do not inherit handles
            EXTENDED_STARTUPINFO_PRESENT,
            null,
            wd_ptr,
            &startup_info,
            &proc_info,
        ) == 0) {
            return ConPtyError.CreateProcessFailed;
        }

        self.process_info = proc_info;
    }

    /// Read bytes from the child process output.
    /// Returns number of bytes read, or error on failure.
    pub fn read(self: *ConPty, buf: []u8) ConPtyError!usize {
        var bytes_read: DWORD = 0;
        if (ReadFile(
            self.output_read,
            buf.ptr,
            @intCast(buf.len),
            &bytes_read,
            null,
        ) == 0) {
            // Check if process ended (broken pipe)
            const err = GetLastError();
            if (err == 109) { // ERROR_BROKEN_PIPE
                return 0;
            }
            return ConPtyError.ReadFailed;
        }
        return @intCast(bytes_read);
    }

    /// Write bytes to the child process input.
    /// Returns number of bytes written, or error on failure.
    pub fn write(self: *ConPty, data: []const u8) ConPtyError!usize {
        var bytes_written: DWORD = 0;
        if (WriteFile(
            self.input_write,
            data.ptr,
            @intCast(data.len),
            &bytes_written,
            null,
        ) == 0) {
            return ConPtyError.WriteFailed;
        }
        return @intCast(bytes_written);
    }

    /// Resize the pseudo-terminal.
    /// ConPTY handles sending the resize signal to the child process.
    pub fn resize(self: *ConPty, cols: u16, rows: u16) ConPtyError!void {
        const size = COORD{
            .X = @intCast(cols),
            .Y = @intCast(rows),
        };
        const hr = ResizePseudoConsole(self.hpc, size);
        if (hr < 0) {
            return ConPtyError.ResizeFailed;
        }
    }

    /// Get the child process ID for management.
    pub fn getChildPid(self: *const ConPty) ?i32 {
        if (self.process_info.dwProcessId == 0) return null;
        return @intCast(self.process_info.dwProcessId);
    }

    /// Query the child process's current working directory via NtQueryInformationProcess.
    /// Returns the CWD as a UTF-8 slice into the provided buffer, or null on failure.
    pub fn getChildCwd(self: *const ConPty, buf: []u8) ?[]const u8 {
        if (self.process_info.hProcess == INVALID_HANDLE_VALUE) return null;

        // Read the PEB address from the child process
        var pbi: PROCESS_BASIC_INFORMATION = undefined;
        var return_len: DWORD = 0;
        const status = NtQueryInformationProcess(
            self.process_info.hProcess,
            0, // ProcessBasicInformation
            &pbi,
            @sizeOf(PROCESS_BASIC_INFORMATION),
            &return_len,
        );
        if (status != 0) return null;

        const peb_addr = pbi.PebBaseAddress orelse return null;

        // Read RTL_USER_PROCESS_PARAMETERS pointer from PEB
        // Offset of ProcessParameters in PEB is 0x20 on x64
        const params_offset = 0x20;
        var params_ptr: usize = 0;
        var bytes_read: usize = 0;
        if (ReadProcessMemory(
            self.process_info.hProcess,
            @ptrFromInt(@intFromPtr(peb_addr) + params_offset),
            @ptrCast(&params_ptr),
            @sizeOf(usize),
            &bytes_read,
        ) == 0) return null;

        // Read CurrentDirectory.Buffer (UNICODE_STRING at offset 0x38 in RTL_USER_PROCESS_PARAMETERS on x64)
        // UNICODE_STRING: Length (u16) + MaxLength (u16) + padding + Buffer (ptr)
        const cwd_offset = 0x38;
        var cwd_length: u16 = 0;
        if (ReadProcessMemory(
            self.process_info.hProcess,
            @ptrFromInt(params_ptr + cwd_offset),
            @ptrCast(&cwd_length),
            @sizeOf(u16),
            &bytes_read,
        ) == 0) return null;

        if (cwd_length == 0) return null;

        var cwd_buffer_ptr: usize = 0;
        if (ReadProcessMemory(
            self.process_info.hProcess,
            @ptrFromInt(params_ptr + cwd_offset + 8), // Buffer pointer is at +8 in UNICODE_STRING
            @ptrCast(&cwd_buffer_ptr),
            @sizeOf(usize),
            &bytes_read,
        ) == 0) return null;

        // Read the actual CWD string (UTF-16)
        const wchar_len = cwd_length / 2;
        var wbuf: [512]u16 = undefined;
        if (wchar_len > wbuf.len) return null;

        if (ReadProcessMemory(
            self.process_info.hProcess,
            @ptrFromInt(cwd_buffer_ptr),
            @ptrCast(wbuf[0..wchar_len]),
            cwd_length,
            &bytes_read,
        ) == 0) return null;

        // Strip trailing backslash (e.g., "C:\Users\foo\" -> "C:\Users\foo")
        var effective_len = wchar_len;
        if (effective_len > 1 and wbuf[effective_len - 1] == '\\') {
            effective_len -= 1;
        }

        // Convert UTF-16 to UTF-8
        const utf8_len = std.unicode.utf16LeToUtf8(buf, wbuf[0..effective_len]) catch return null;
        return buf[0..utf8_len];
    }

    /// Clean up all ConPTY resources.
    /// Shutdown sequence (matches working standalone pattern):
    /// 1. Terminate child process + wait for exit
    /// 2. Close input pipe
    /// 3. ClosePseudoConsole on background thread
    /// 4. Blocking ReadFile drain on main thread until pipe breaks
    /// 5. Join close thread, close remaining handles
    pub fn deinit(self: *ConPty) void {
        // 1. Terminate the child process and wait for exit
        if (self.process_info.hProcess != INVALID_HANDLE_VALUE) {
            _ = TerminateProcess(self.process_info.hProcess, 0);
            _ = WaitForSingleObject(self.process_info.hProcess, 5000);
        }

        // 2. Close input pipe
        if (self.input_write != INVALID_HANDLE_VALUE) {
            _ = CloseHandle(self.input_write);
            self.input_write = INVALID_HANDLE_VALUE;
        }

        // 3. ClosePseudoConsole on background thread
        const hpc_copy = self.hpc;
        const close_thread = std.Thread.spawn(.{}, struct {
            fn run(hpc: HPCON) void {
                ClosePseudoConsole(hpc);
            }
        }.run, .{hpc_copy}) catch blk: {
            // Fallback: close synchronously to avoid infinite hang in the drain loop.
            // This may deadlock under heavy I/O, but that is preferable to a guaranteed
            // infinite hang when no thread is available to break the pipe.
            ClosePseudoConsole(hpc_copy);
            self.hpc = INVALID_HANDLE_VALUE;
            break :blk null;
        };

        // 4. Drain output pipe with timeout (PeekNamedPipe + ReadFile).
        //    When ClosePseudoConsole completes, it breaks the pipe, and
        //    ReadFile returns with error 109 (ERROR_BROKEN_PIPE).
        //    Use PeekNamedPipe to avoid blocking forever if the pipe isn't broken in time.
        if (self.output_read != INVALID_HANDLE_VALUE) {
            var drain_buf: [4096]u8 = undefined;
            var bytes_read: DWORD = 0;
            const drain_deadline = std.time.milliTimestamp() + 5000;
            while (std.time.milliTimestamp() < drain_deadline) {
                var avail: DWORD = 0;
                if (PeekNamedPipe(self.output_read, null, 0, null, &avail, null) == 0) break; // pipe broken
                if (avail > 0) {
                    if (ReadFile(self.output_read, &drain_buf, drain_buf.len, &bytes_read, null) == 0) break;
                    if (bytes_read == 0) break;
                } else {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                }
            }
            _ = CloseHandle(self.output_read);
            self.output_read = INVALID_HANDLE_VALUE;
        }

        // 5. Join close thread
        if (close_thread) |t| t.join();

        // 6. Close process handles
        if (self.process_info.hProcess != INVALID_HANDLE_VALUE) {
            _ = CloseHandle(self.process_info.hProcess);
        }
        if (self.process_info.hThread != INVALID_HANDLE_VALUE) {
            _ = CloseHandle(self.process_info.hThread);
        }

        // 7. Free attribute list buffer
        if (self.attribute_list_buf) |buf| {
            const attr_list: LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast(buf.ptr);
            DeleteProcThreadAttributeList(attr_list);
            self.allocator.free(buf);
        }
    }
};
