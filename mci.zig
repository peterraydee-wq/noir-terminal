//! noirterm/mci.zig
//!
//! Real audio playback via Windows' legacy MCI (Media Control
//! Interface, winmm.dll) — a plain C-ABI string-command API dating to
//! Windows 3.1, not COM. Chosen deliberately over WASAPI/Media
//! Foundation: those are COM interfaces on the scale of (or bigger
//! than) Direct2D, and this project only has budget to get one COM
//! subsystem right per pass — MCI gets real playback with none of that
//! risk, at the cost of coarser control (no custom DSP/mixing, just
//! open/play/pause/stop/query).
//!
//! Windows-only by nature (there's no MCI on any other platform) —
//! this file simply isn't compiled on non-Windows targets;
//! musicplayer_main.zig swaps in a simulated player there instead, so
//! the TUI navigation logic is still testable in this dev sandbox.
//!
//! VERIFICATION STATUS: cross-compiles and links against winmm.dll.
//! Real playback has NOT been confirmed on Windows — no audio hardware
//! to test against here even in principle. The command syntax below
//! matches Microsoft's documented MCI string-command reference.

const std = @import("std");
const win32 = @import("win32.zig");

extern "winmm" fn mciSendStringW(
    lpszCommand: win32.LPCWSTR,
    lpszReturnString: ?[*]u16,
    cchReturn: u32,
    hwndCallback: ?win32.HWND,
) callconv(.winapi) u32;

fn sendCommand(comptime fmt: []const u8, args: anytype) bool {
    var utf8_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrint(&utf8_buf, fmt, args) catch return false;
    var wide_buf: [512]u16 = undefined;
    const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, cmd) catch return false;
    if (wide_len >= wide_buf.len) return false;
    wide_buf[wide_len] = 0;
    return mciSendStringW(wide_buf[0..wide_len :0].ptr, null, 0, null) == 0;
}

fn queryStatus(comptime fmt: []const u8, args: anytype, out: []u8) ?[]const u8 {
    var utf8_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrint(&utf8_buf, fmt, args) catch return null;
    var wide_buf: [512]u16 = undefined;
    const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, cmd) catch return null;
    if (wide_len >= wide_buf.len) return null;
    wide_buf[wide_len] = 0;
    var ret_wide: [64]u16 = undefined;
    const rc = mciSendStringW(wide_buf[0..wide_len :0].ptr, &ret_wide, ret_wide.len, null);
    if (rc != 0) return null;
    const ret_len = std.mem.indexOfScalar(u16, &ret_wide, 0) orelse ret_wide.len;
    const n = std.unicode.utf16LeToUtf8(out, ret_wide[0..ret_len]) catch return null;
    return out[0..n];
}

pub const Player = struct {
    alias: []const u8 = "noirplay_track",
    is_open: bool = false,

    pub fn open(self: *Player, path: []const u8) bool {
        self.close();
        const ok = sendCommand("open \"{s}\" alias {s}", .{ path, self.alias });
        self.is_open = ok;
        return ok;
    }

    pub fn play(self: *Player) void {
        if (self.is_open) _ = sendCommand("play {s}", .{self.alias});
    }

    pub fn pause(self: *Player) void {
        if (self.is_open) _ = sendCommand("pause {s}", .{self.alias});
    }

    pub fn stop(self: *Player) void {
        if (self.is_open) _ = sendCommand("stop {s}", .{self.alias});
    }

    pub fn close(self: *Player) void {
        if (self.is_open) {
            _ = sendCommand("close {s}", .{self.alias});
            self.is_open = false;
        }
    }

    /// Position in milliseconds, or null if unavailable.
    pub fn positionMs(self: *Player, buf: []u8) ?u64 {
        if (!self.is_open) return null;
        const s = queryStatus("status {s} position", .{self.alias}, buf) orelse return null;
        return std.fmt.parseInt(u64, s, 10) catch null;
    }

    /// Length in milliseconds, or null if unavailable.
    pub fn lengthMs(self: *Player, buf: []u8) ?u64 {
        if (!self.is_open) return null;
        const s = queryStatus("status {s} length", .{self.alias}, buf) orelse return null;
        return std.fmt.parseInt(u64, s, 10) catch null;
    }

    pub fn isPlaying(self: *Player, buf: []u8) bool {
        if (!self.is_open) return false;
        const s = queryStatus("status {s} mode", .{self.alias}, buf) orelse return false;
        return std.mem.eql(u8, s, "playing");
    }
};
