//! noirterm/pty_windows.zig
//!
//! Native Windows PTY backend via ConPTY (Windows 10 1809+), the actual
//! target platform for this project. The shape of the work is quite
//! different from the Linux /dev/ptmx dance, but the *result* — a Pty
//! with read/write/resize/close that the parser and grid never need to
//! know is platform-specific — is identical:
//!
//!   1. CreatePipe() x2 — one pipe carries bytes INTO the pseudoconsole
//!      (our keystrokes), one carries bytes OUT of it (the child's screen
//!      output). We keep one end of each; ConPTY gets the other ends.
//!   2. CreatePseudoConsole(size, inPipeRead, outPipeWrite, 0, &hpc)
//!   3. Build a STARTUPINFOEXW with the PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
//!      attribute pointing at hpc, and CreateProcessW the child with
//!      EXTENDED_STARTUPINFO_PRESENT — this is what actually attaches the
//!      new process's console to our pseudoconsole instead of a real one.
//!   4. Read from outPipeRead / write to inPipeWrite exactly like a normal
//!      pipe — ConPTY translates the child's console I/O into a VT byte
//!      stream on the way out, and VT input sequences into console input
//!      events on the way in.
//!
//! kernel32 doesn't expose ConPTY or the ProcThreadAttributeList family
//! through Zig's std.os.windows bindings (they're a fairly modern, fairly
//! niche corner of Win32), so those are declared here directly against
//! Microsoft's documented ABI. CreateProcessW/STARTUPINFOW/PROCESS.INFORMATION
//! *are* in std.os.windows already and are reused as-is.
//!
//! IMPORTANT — verification status: this compiles and cross-compiles
//! cleanly (checked via `zig build -Dtarget=x86_64-windows-gnu`), but it
//! has NOT been run on real Windows yet — this sandbox has no Windows
//! runtime to execute against. Treat the type-level plumbing as solid and
//! the runtime behavior as "needs a real test pass on your machine."

const std = @import("std");
const windows = std.os.windows;

const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const WORD = windows.WORD;
const COORD = windows.COORD;
const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
const STARTUPINFOW = windows.STARTUPINFOW;
const PROCESS_INFORMATION = windows.PROCESS.INFORMATION;

/// Opaque pseudoconsole handle (HPCON in the Windows SDK).
const HPCON = *anyopaque;

const S_OK: i32 = 0;

const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;

const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

// --- extern declarations not present in std.os.windows ---

extern "kernel32" fn CreatePipe(
    hReadPipe: *HANDLE,
    hWritePipe: *HANDLE,
    lpPipeAttributes: ?*SECURITY_ATTRIBUTES,
    nSize: DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: HANDLE,
    hOutput: HANDLE,
    dwFlags: DWORD,
    phPC: *HPCON,
) callconv(.winapi) i32; // HRESULT

extern "kernel32" fn ResizePseudoConsole(
    hPC: HPCON,
    size: COORD,
) callconv(.winapi) i32; // HRESULT

extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;

extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?*anyopaque,
    dwAttributeCount: DWORD,
    dwFlags: DWORD,
    lpSize: *usize,
) callconv(.winapi) BOOL;

// mingw-w64's bundled kernel32.def (at least the copy shipped with this
// Zig toolchain) lists this symbol as `UpdateProcThreadAttribute`,
// missing the "List" suffix that the real Win32 API — and MSVC's own
// kernel32.lib — actually uses. Binding by name explicitly here so the
// gnu/mingw target links against what its import lib actually has,
// while an msvc target (recommended for the real build — see pty
// backend notes) uses the correct full name.
const UpdateProcThreadAttributeListFn = *const fn (
    lpAttributeList: *anyopaque,
    dwFlags: DWORD,
    Attribute: usize,
    lpValue: *anyopaque,
    cbSize: usize,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*usize,
) callconv(.winapi) BOOL;

const UpdateProcThreadAttributeList: UpdateProcThreadAttributeListFn = @extern(UpdateProcThreadAttributeListFn, .{
    .name = if (@import("builtin").abi == .gnu) "UpdateProcThreadAttribute" else "UpdateProcThreadAttributeList",
    .library_name = "kernel32",
});

extern "kernel32" fn DeleteProcThreadAttributeList(
    lpAttributeList: *anyopaque,
) callconv(.winapi) void;

pub const PtyError = error{
    CreatePipeFailed,
    CreatePseudoConsoleFailed,
    AttributeListFailed,
    CreateProcessFailed,
    OutOfMemory,
};

pub const Pty = struct {
    hpc: HPCON,
    input_write: HANDLE, // we write here; ConPTY reads it as keystrokes
    output_read: HANDLE, // we read here; ConPTY writes rendered VT output
    process: HANDLE,
    thread: HANDLE,
    child_pid: u32,
    attr_list_buf: []u8, // kept alive until close(); freed there

    pub fn spawn(allocator: std.mem.Allocator, argv: []const []const u8, cols: u16, rows: u16) !Pty {
        var in_read: HANDLE = undefined;
        var in_write: HANDLE = undefined;
        var out_read: HANDLE = undefined;
        var out_write: HANDLE = undefined;

        if (!CreatePipe(&in_read, &in_write, null, 0).toBool()) return PtyError.CreatePipeFailed;
        errdefer windows.CloseHandle(in_write);
        if (!CreatePipe(&out_read, &out_write, null, 0).toBool()) return PtyError.CreatePipeFailed;
        errdefer windows.CloseHandle(out_read);

        var hpc: HPCON = undefined;
        const size = COORD{ .X = @intCast(cols), .Y = @intCast(rows) };
        const hr = CreatePseudoConsole(size, in_read, out_write, 0, &hpc);
        // ConPTY duplicates the handles it needs internally; our copies of
        // the ends we handed over are no longer needed once it's created.
        windows.CloseHandle(in_read);
        windows.CloseHandle(out_write);
        if (hr != S_OK) return PtyError.CreatePseudoConsoleFailed;
        errdefer ClosePseudoConsole(hpc);

        // --- build the attribute list that attaches hpc to CreateProcess ---
        var attr_list_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size);
        const attr_list_buf = try allocator.alignedAlloc(u8, .of(usize), attr_list_size);
        errdefer allocator.free(attr_list_buf);
        const attr_list: *anyopaque = attr_list_buf.ptr;

        if (!InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_list_size).toBool())
            return PtyError.AttributeListFailed;
        defer DeleteProcThreadAttributeList(attr_list);

        var hpc_value = hpc;
        if (!UpdateProcThreadAttributeList(
            attr_list,
            0,
            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            @ptrCast(&hpc_value),
            @sizeOf(HPCON),
            null,
            null,
        ).toBool()) return PtyError.AttributeListFailed;

        // --- command line: quote argv per the MSVCRT convention ---
        const cmdline_w = try buildCommandLineW(allocator, argv);
        defer allocator.free(cmdline_w);

        var startup_ex = std.mem.zeroes(STARTUPINFOEXW);
        startup_ex.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
        startup_ex.lpAttributeList = attr_list;

        var proc_info: PROCESS_INFORMATION = std.mem.zeroes(PROCESS_INFORMATION);

        const create_ok = windows.kernel32.CreateProcessW(
            null,
            cmdline_w.ptr,
            null,
            null,
            windows.BOOL.FALSE, // bInheritHandles — ConPTY doesn't need classic handle inheritance
            .{ .extended_startupinfo_present = true },
            null, // inherit parent's environment
            null, // inherit parent's current directory
            &startup_ex.StartupInfo,
            &proc_info,
        );
        if (!create_ok.toBool()) return PtyError.CreateProcessFailed;
        windows.CloseHandle(in_read); // no-op guard if already closed above
        windows.CloseHandle(out_write);

        return Pty{
            .hpc = hpc,
            .input_write = in_write,
            .output_read = out_read,
            .process = proc_info.hProcess,
            .thread = proc_info.hThread,
            .child_pid = proc_info.dwProcessId,
            .attr_list_buf = attr_list_buf,
        };
    }

    pub fn write(self: *Pty, bytes: []const u8) usize {
        var written: DWORD = 0;
        _ = WriteFile(self.input_write, bytes.ptr, @intCast(bytes.len), &written, null);
        return written;
    }

    /// Returns 0 on EOF/error (matches pty_linux's convention), else the
    /// number of bytes read.
    pub fn read(self: *Pty, buf: []u8) usize {
        var got: DWORD = 0;
        if (!ReadFile(self.output_read, buf.ptr, @intCast(buf.len), &got, null).toBool()) return 0;
        return got;
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) void {
        _ = ResizePseudoConsole(self.hpc, COORD{ .X = @intCast(cols), .Y = @intCast(rows) });
    }

    pub fn close(self: *Pty) void {
        ClosePseudoConsole(self.hpc);
        windows.CloseHandle(self.input_write);
        windows.CloseHandle(self.output_read);
        windows.CloseHandle(self.thread);
        windows.CloseHandle(self.process);
    }
};

/// Builds a single UTF-16 command-line string from argv, applying the
/// documented MSVCRT argv-quoting algorithm (the one every Windows program
/// expects its command line pre-quoted with) — backslash-run + quote
/// escaping so args containing spaces or quotes round-trip correctly.
fn buildCommandLineW(allocator: std.mem.Allocator, argv: []const []const u8) ![:0]u16 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    for (argv, 0..) |arg, idx| {
        if (idx != 0) try line.append(allocator, ' ');
        const needs_quotes = arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\"") != null;
        if (!needs_quotes) {
            try line.appendSlice(allocator, arg);
            continue;
        }
        try line.append(allocator, '"');
        var backslashes: usize = 0;
        for (arg) |c| {
            if (c == '\\') {
                backslashes += 1;
                continue;
            }
            if (c == '"') {
                try line.appendNTimes(allocator, '\\', backslashes * 2 + 1);
                backslashes = 0;
                try line.append(allocator, '"');
                continue;
            }
            try line.appendNTimes(allocator, '\\', backslashes);
            backslashes = 0;
            try line.append(allocator, c);
        }
        try line.appendNTimes(allocator, '\\', backslashes * 2);
        try line.append(allocator, '"');
    }

    return std.unicode.utf8ToUtf16LeAllocZ(allocator, line.items);
}
