//! noirterm/prompt_main.zig
//!
//! Standalone prompt-generator binary — the "widgets" phase, built the
//! same way real starship is built: a separate program any shell can
//! invoke, not something baked into the terminal emulator itself.
//! Reads the calling shell's last exit code from argv[1], gathers cwd
//! and git branch, and prints an ANSI-formatted prompt line to stdout.
//!
//! cmd.exe doesn't have a rich enough prompt hook to call an external
//! program and capture its output automatically, but PowerShell's
//! `prompt` function can, and this is exactly the shape phase 9's own
//! shell would call this the same way. Example PowerShell integration
//! (put in your `$PROFILE`):
//!
//!   function prompt {
//!       $exit = $LASTEXITCODE; if ($null -eq $exit) { $exit = 0 }
//!       & "path\to\noirprompt.exe" $exit
//!       return " "
//!   }
//!
//! VERIFICATION STATUS: cross-compiles and links. The Windows-specific
//! gathering (GetCurrentDirectoryW, GetEnvironmentVariableW) is untested
//! on real Windows like the rest of this project's OS glue; prompt.zig's
//! actual composition logic is separately unit-tested and confirmed
//! correct, and this binary does run successfully on Linux (this
//! sandbox's fast-iteration path) using the getcwd/environ equivalents.

const std = @import("std");
const builtin = @import("builtin");
const color = @import("color.zig");
const prompt = @import("prompt.zig");
const gitinfo = @import("gitinfo.zig");

fn getCwd(buf: []u8) []const u8 {
    if (builtin.os.tag == .windows) {
        const win32 = @import("win32.zig");
        var wide_buf: [512]u16 = undefined;
        const len = win32.GetCurrentDirectoryW(wide_buf.len, &wide_buf);
        if (len == 0 or len >= wide_buf.len) return "?";
        const n = std.unicode.utf16LeToUtf8(buf, wide_buf[0..len]) catch return "?";
        return buf[0..n];
    } else {
        const linux = std.os.linux;
        const rc = linux.getcwd(buf.ptr, buf.len);
        if (@as(isize, @bitCast(rc)) < 0) return "?";
        return std.mem.sliceTo(buf, 0);
    }
}

fn getEnvVar(buf: []u8, name: []const u8) []const u8 {
    if (builtin.os.tag == .windows) {
        const win32 = @import("win32.zig");
        var name_wide: [64]u16 = undefined;
        const name_len = std.unicode.utf8ToUtf16Le(&name_wide, name) catch return "";
        if (name_len >= name_wide.len) return "";
        name_wide[name_len] = 0;
        var wide_buf: [256]u16 = undefined;
        const len = win32.GetEnvironmentVariableW(name_wide[0..name_len :0], &wide_buf, wide_buf.len);
        if (len == 0 or len >= wide_buf.len) return "";
        const n = std.unicode.utf16LeToUtf8(buf, wide_buf[0..len]) catch return "";
        return buf[0..n];
    } else {
        // POSIX doesn't need the USERNAME/COMPUTERNAME lookup at all in
        // practice for this tool's current use (only cwd/git feed the
        // prompt today) — left unimplemented here rather than adding
        // untested surface for a value nothing currently consumes.
        return "";
    }
}

fn writeStdout(bytes: []const u8) void {
    if (builtin.os.tag == .windows) {
        const win32 = @import("win32.zig");
        const STD_OUTPUT_HANDLE: i32 = -11;
        const handle = GetStdHandle(STD_OUTPUT_HANDLE) orelse return;
        var written: win32.DWORD = 0;
        _ = win32.WriteFile(handle, bytes.ptr, @intCast(bytes.len), &written, null);
    } else {
        _ = std.os.linux.write(1, bytes.ptr, bytes.len);
    }
}

extern "kernel32" fn GetStdHandle(nStdHandle: i32) callconv(.winapi) ?*anyopaque;

fn getExitCodeArg() u8 {
    if (builtin.os.tag == .windows) {
        // std.process.Args churned significantly in this Zig version
        // (mid-transition to a new async Io model) — going straight to
        // the PEB's command line, same expression start.zig itself uses
        // internally, sidesteps that entirely. Our only argument is a
        // bare integer with no spaces/quoting to worry about, so "take
        // the last whitespace-separated token" is enough; a bare exe
        // path with no args just fails to parse and falls back to 0.
        const wide = std.os.windows.peb().ProcessParameters.CommandLine.slice();
        var utf8_buf: [512]u8 = undefined;
        const n = std.unicode.utf16LeToUtf8(&utf8_buf, wide) catch return 0;
        var it = std.mem.tokenizeAny(u8, utf8_buf[0..n], " \t");
        var last: []const u8 = "";
        while (it.next()) |tok| last = tok;
        return std.fmt.parseInt(u8, last, 10) catch 0;
    } else {
        // /proc/self/cmdline: NUL-separated argv; argv[0] is our own
        // path, skip it and take the next NUL-delimited token.
        const linux = std.os.linux;
        const fd_rc = linux.open("/proc/self/cmdline", .{ .ACCMODE = .RDONLY }, 0);
        if (@as(isize, @bitCast(fd_rc)) < 0) return 0;
        const fd: i32 = @intCast(fd_rc);
        defer _ = linux.close(fd);
        var buf: [512]u8 = undefined;
        const n = linux.read(fd, &buf, buf.len);
        if (@as(isize, @bitCast(n)) < 0) return 0;
        const data = buf[0..n];
        const first_nul = std.mem.indexOfScalar(u8, data, 0) orelse return 0;
        const rest = data[first_nul + 1 ..];
        if (rest.len == 0) return 0;
        const second_end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
        return std.fmt.parseInt(u8, rest[0..second_end], 10) catch 0;
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    const exit_code = getExitCodeArg();

    var cwd_buf: [1024]u8 = undefined;
    const cwd = getCwd(&cwd_buf);
    const branch = gitinfo.findBranch(allocator, cwd);
    defer if (branch) |b| allocator.free(b);

    const line = try prompt.compose(allocator, color.active, .{
        .cwd = cwd,
        .git_branch = branch,
        .exit_code = exit_code,
    });
    defer allocator.free(line);
    writeStdout(line);
}
