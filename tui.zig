//! noirterm/tui.zig
//!
//! Shared plumbing for the standalone TUI tools that get spawned into a
//! pane (file manager, music player) the same way any other program
//! does — over the pane's PTY, which noirterm already speaks VT to.
//! These tools are ordinary console programs from their own point of
//! view; they just happen to usually run inside a noirterm pane.
//!
//! Key decoding reuses vt/parser.zig — the same state machine that
//! decodes a *shell's* output also happens to correctly decode the
//! escape sequences a terminal sends *for* arrow keys (`CSI A/B/C/D`
//! with no parameters), so there's no second parser to get right here.
//!
//! Raw mode: on Windows this needs `SetConsoleMode` even though the
//! "console" here is a ConPTY pane, not a real console session — from
//! the child process's own perspective it looks like an ordinary
//! console, line-buffered and echoing by default, same as any Windows
//! console program. Linux support (termios) exists purely so these
//! tools are testable in this dev sandbox, which has no ConPTY.

const std = @import("std");
const builtin = @import("builtin");
const color = @import("color.zig");
const vt = @import("vt/parser.zig");

const win32 = if (builtin.os.tag == .windows) @import("win32.zig") else struct {};

pub const Key = union(enum) {
    up,
    down,
    left,
    right,
    enter,
    backspace,
    char: u21,
};

pub const RawMode = struct {
    windows_in: if (builtin.os.tag == .windows) win32.HANDLE else void = undefined,
    windows_out: if (builtin.os.tag == .windows) win32.HANDLE else void = undefined,
    windows_old_in: if (builtin.os.tag == .windows) win32.DWORD else void = undefined,
    windows_old_out: if (builtin.os.tag == .windows) win32.DWORD else void = undefined,
    posix_old: if (builtin.os.tag != .windows) std.os.linux.termios else void = undefined,

    pub fn enable() RawMode {
        var self: RawMode = .{};
        if (builtin.os.tag == .windows) {
            self.windows_in = win32.GetStdHandle(win32.STD_INPUT_HANDLE);
            self.windows_out = win32.GetStdHandle(win32.STD_OUTPUT_HANDLE);
            _ = win32.GetConsoleMode(self.windows_in, &self.windows_old_in);
            _ = win32.GetConsoleMode(self.windows_out, &self.windows_old_out);
            const new_in = (self.windows_old_in & ~(win32.ENABLE_LINE_INPUT | win32.ENABLE_ECHO_INPUT | win32.ENABLE_PROCESSED_INPUT)) | win32.ENABLE_VIRTUAL_TERMINAL_INPUT;
            _ = win32.SetConsoleMode(self.windows_in, new_in);
            _ = win32.SetConsoleMode(self.windows_out, self.windows_old_out | win32.ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        } else {
            const linux = std.os.linux;
            var t: linux.termios = undefined;
            _ = linux.tcgetattr(0, &t);
            self.posix_old = t;
            t.lflag.ICANON = false;
            t.lflag.ECHO = false;
            t.lflag.ISIG = false;
            _ = linux.tcsetattr(0, .NOW, &t);
        }
        return self;
    }

    pub fn disable(self: *RawMode) void {
        if (builtin.os.tag == .windows) {
            _ = win32.SetConsoleMode(self.windows_in, self.windows_old_in);
            _ = win32.SetConsoleMode(self.windows_out, self.windows_old_out);
        } else {
            _ = std.os.linux.tcsetattr(0, .NOW, &self.posix_old);
        }
    }
};

fn readStdinByte() ?u8 {
    var buf: [1]u8 = undefined;
    if (builtin.os.tag == .windows) {
        const h = win32.GetStdHandle(win32.STD_INPUT_HANDLE);
        var read: win32.DWORD = 0;
        if (win32.ReadFile(h, &buf, 1, &read, null) == win32.BOOL.FALSE or read == 0) return null;
    } else {
        const n = std.os.linux.read(0, &buf, 1);
        if (@as(isize, @bitCast(n)) <= 0) return null;
    }
    return buf[0];
}

/// Blocks until a full key is decoded. Known gap: a bare Escape key
/// (not part of an arrow-key sequence) is swallowed rather than
/// reported — disambiguating it from the start of a sequence needs a
/// short timeout after a lone ESC byte, which needs non-blocking reads
/// this simple loop doesn't do. Not needed for these tools: quit is
/// bound to 'q', not Escape.
pub fn readKey(parser: *vt.Parser) ?Key {
    while (true) {
        const byte = readStdinByte() orelse return null;
        const action = parser.feed(byte) orelse continue;
        switch (action) {
            .csi_dispatch => |csi| {
                if (csi.params.len == 0) {
                    switch (csi.final) {
                        'A' => return .up,
                        'B' => return .down,
                        'C' => return .right,
                        'D' => return .left,
                        else => continue,
                    }
                }
            },
            .execute => |b| {
                if (b == '\r' or b == '\n') return .enter;
                if (b == 0x08 or b == 0x7f) return .backspace;
            },
            .print => |cp| {
                if (cp == 0x7f) return .backspace;
                return .{ .char = cp };
            },
            else => {},
        }
    }
}

// --- ANSI drawing helpers ---

pub fn clearScreen(out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try out.appendSlice(allocator, "\x1b[2J\x1b[H");
}

pub fn moveCursor(out: *std.ArrayList(u8), allocator: std.mem.Allocator, row: usize, col: usize) !void {
    var buf: [32]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row + 1, col + 1 }));
}

pub fn setFg(out: *std.ArrayList(u8), allocator: std.mem.Allocator, rgb: color.Rgb) !void {
    var buf: [32]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }));
}

pub fn setBg(out: *std.ArrayList(u8), allocator: std.mem.Allocator, rgb: color.Rgb) !void {
    var buf: [32]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "\x1b[48;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }));
}

pub fn reset(out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try out.appendSlice(allocator, "\x1b[0m");
}

pub fn writeStdout(bytes: []const u8) void {
    if (builtin.os.tag == .windows) {
        const h = win32.GetStdHandle(win32.STD_OUTPUT_HANDLE);
        var written: win32.DWORD = 0;
        _ = win32.WriteFile(h, bytes.ptr, @intCast(bytes.len), &written, null);
    } else {
        _ = std.os.linux.write(1, bytes.ptr, bytes.len);
    }
}
