//! noirterm/pty_linux.zig
//!
//! Raw Linux PTY handling: no libc, direct syscalls via std.os.linux.
//! This is the classic /dev/ptmx dance (see `man pts`, `man ptmx`):
//!
//!   1. open("/dev/ptmx")         -> master fd, kernel auto-allocates a slave
//!   2. ioctl(TIOCSPTLCK, 0)      -> unlock the slave (== unlockpt)
//!   3. ioctl(TIOCGPTN, &n)       -> ask which /dev/pts/<n> we got (== ptsname)
//!   4. fork()
//!        child:  setsid(), open the slave, TIOCSCTTY to make it our
//!                controlling terminal, dup2 onto 0/1/2, execve the shell
//!        parent: keep the master fd, talk to the child over it
//!
//! Exposes the same portable `Pty` surface (`spawn`/`read`/`write`/
//! `resize`/`close`) as pty_windows.zig — see pty.zig for the dispatcher.

const std = @import("std");
const linux = std.os.linux;

const TIOCGPTN: u32 = 0x80045430; // _IOR('T', 0x30, unsigned int)
const TIOCSPTLCK: u32 = 0x40045431; // _IOW('T', 0x31, int)
const TIOCSCTTY: u32 = 0x540E;
const TIOCSWINSZ: u32 = 0x5414;

const WinSize = extern struct {
    row: u16,
    col: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

pub const PtyError = error{
    OpenPtmxFailed,
    UnlockFailed,
    GetPtNumberFailed,
    ForkFailed,
    OutOfMemory,
    TooManyArgs,
};

fn isErr(rc: usize) bool {
    return @as(isize, @bitCast(rc)) < 0;
}

/// Reads a whole file via raw syscalls only (used for /proc/self/environ).
fn readAllRaw(allocator: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const fd_rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (isErr(fd_rc)) return error.OpenPtmxFailed;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);

    var list: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        const signed_n: isize = @bitCast(n);
        if (signed_n <= 0) break;
        try list.appendSlice(allocator, buf[0..@intCast(signed_n)]);
    }
    return list.toOwnedSlice(allocator);
}

/// Inherits the current process's environment for the child, plus a
/// guaranteed TERM. /proc/self/environ is NUL-separated "KEY=VALUE" pairs.
fn buildEnvp(allocator: std.mem.Allocator) ![]?[*:0]const u8 {
    const raw = try readAllRaw(allocator, "/proc/self/environ");
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == 0) {
            const entry = raw[start..i :0];
            try list.append(allocator, entry.ptr);
            start = i + 1;
        }
    }
    try list.append(allocator, "TERM=xterm-256color");
    try list.append(allocator, null);
    return list.toOwnedSlice(allocator);
}

/// Converts a portable `[]const []const u8` argv into a NUL-terminated
/// array of NUL-terminated C strings, matching execve()'s convention.
fn buildArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    for (argv) |arg| {
        const z = try allocator.dupeZ(u8, arg);
        try list.append(allocator, z.ptr);
    }
    try list.append(allocator, null);
    return list.toOwnedSlice(allocator);
}

pub const Pty = struct {
    master_fd: i32,
    child_pid: i32,

    /// Spawn `argv[0]` (with the rest of `argv` as its arguments) attached
    /// to a fresh PTY, inheriting the current process's environment.
    pub fn spawn(allocator: std.mem.Allocator, argv: []const []const u8, cols: u16, rows: u16) !Pty {
        const argv_z = try buildArgv(allocator, argv);
        const envp_z = try buildEnvp(allocator);
        const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv_z.ptr);
        const envp_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(envp_z.ptr);

        const master_rc = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        if (isErr(master_rc)) return PtyError.OpenPtmxFailed;
        const master_fd: i32 = @intCast(master_rc);
        errdefer _ = linux.close(master_fd);

        var unlock_val: c_int = 0;
        if (isErr(linux.ioctl(master_fd, TIOCSPTLCK, @intFromPtr(&unlock_val))))
            return PtyError.UnlockFailed;

        var ptn: c_uint = 0;
        if (isErr(linux.ioctl(master_fd, TIOCGPTN, @intFromPtr(&ptn))))
            return PtyError.GetPtNumberFailed;

        var path_buf: [64]u8 = undefined;
        const slave_path = std.fmt.bufPrintZ(&path_buf, "/dev/pts/{d}", .{ptn}) catch
            return PtyError.GetPtNumberFailed;

        var ws = WinSize{ .row = rows, .col = cols };
        _ = linux.ioctl(master_fd, TIOCSWINSZ, @intFromPtr(&ws));

        const pid_rc = linux.fork();
        if (isErr(pid_rc)) return PtyError.ForkFailed;
        const pid: i32 = @intCast(pid_rc);

        if (pid == 0) {
            // --- child: become the pty's session leader and exec the shell ---
            _ = linux.setsid();

            const slave_rc = linux.open(slave_path.ptr, .{ .ACCMODE = .RDWR }, 0);
            if (isErr(slave_rc)) linux.exit(126);
            const slave_fd: i32 = @intCast(slave_rc);

            _ = linux.ioctl(slave_fd, TIOCSCTTY, 0);
            _ = linux.dup2(slave_fd, 0);
            _ = linux.dup2(slave_fd, 1);
            _ = linux.dup2(slave_fd, 2);
            if (slave_fd > 2) _ = linux.close(slave_fd);
            _ = linux.close(master_fd);

            _ = linux.execve(argv_ptr[0].?, argv_ptr, envp_ptr);
            linux.exit(127); // only reached if execve failed
        }

        // --- parent ---
        return Pty{ .master_fd = master_fd, .child_pid = pid };
    }

    pub fn write(self: *Pty, bytes: []const u8) usize {
        return linux.write(self.master_fd, bytes.ptr, bytes.len);
    }

    /// Returns 0 on EOF/error (matches pty_windows's convention), else the
    /// number of bytes read. NOTE: on Linux, once the child has exited and
    /// closed its end of the pty, read() typically fails with EIO rather
    /// than returning a clean 0 — that's normal PTY behavior, not a real
    /// error, so it's folded into the same "0 = done" signal here rather
    /// than leaking raw errno details to callers.
    pub fn read(self: *Pty, buf: []u8) usize {
        const n = linux.read(self.master_fd, buf.ptr, buf.len);
        if (isErr(n)) return 0;
        return n;
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) void {
        var ws = WinSize{ .row = rows, .col = cols };
        _ = linux.ioctl(self.master_fd, TIOCSWINSZ, @intFromPtr(&ws));
    }

    pub fn close(self: *Pty) void {
        _ = linux.close(self.master_fd);
    }
};
