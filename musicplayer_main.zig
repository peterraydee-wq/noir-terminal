//! noirterm/musicplayer_main.zig
//!
//! Standalone music player binary (`noirplay`) — phase 8's second half,
//! building on the ideas from the user's own cliamp project (ordered
//! local track playback). Same architecture as noirfiles/noirprompt: a
//! separate program spawned into a pane over its PTY, not a native
//! rendering mode baked into the terminal.
//!
//! Controls: Up/Down move the selection, Enter plays the selected
//! track, Space toggles play/pause, Backspace stops, 'q' quits.
//!
//! Real audio playback (mci.zig, Windows-only, MCI-based) is
//! completely unverified — no audio hardware to test against even in
//! principle here. What IS verified: the TUI itself — track-list
//! scanning, navigation, rendering, the play/pause/stop key handling —
//! runs for real on Linux against a `sim.Player` that fakes playback
//! state (a position counter that advances over real wall-clock time),
//! so the interaction logic has actually been exercised even though
//! the audio backend hasn't.

const std = @import("std");
const builtin = @import("builtin");
const color = @import("color.zig");
const tui = @import("tui.zig");
const dirscan = @import("dirscan.zig");
const vt = @import("vt/parser.zig");

const audio_extensions = [_][]const u8{ ".mp3", ".wav", ".wma", ".m4a" };

fn hasAudioExt(name: []const u8) bool {
    for (audio_extensions) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

/// Linux stand-in for mci.Player, real MCI has no non-Windows
/// equivalent. Fakes a playing/paused position that advances with real
/// wall-clock time, so the TUI's progress display and play/pause logic
/// can genuinely be exercised here.
const SimPlayer = struct {
    is_open: bool = false,
    playing: bool = false,
    started_at_ms: i64 = 0,
    accumulated_ms: i64 = 0,

    fn nowMs() i64 {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
    }

    pub fn open(self: *SimPlayer, path: []const u8) bool {
        _ = path;
        self.* = .{ .is_open = true };
        return true;
    }
    pub fn play(self: *SimPlayer) void {
        if (!self.playing) {
            self.playing = true;
            self.started_at_ms = nowMs();
        }
    }
    pub fn pause(self: *SimPlayer) void {
        if (self.playing) {
            self.accumulated_ms += nowMs() - self.started_at_ms;
            self.playing = false;
        }
    }
    pub fn stop(self: *SimPlayer) void {
        self.playing = false;
        self.accumulated_ms = 0;
    }
    pub fn close(self: *SimPlayer) void {
        self.is_open = false;
    }
    pub fn positionMs(self: *SimPlayer, buf: []u8) ?u64 {
        _ = buf;
        if (!self.is_open) return null;
        const extra: i64 = if (self.playing) nowMs() - self.started_at_ms else 0;
        return @intCast(self.accumulated_ms + extra);
    }
    pub fn lengthMs(self: *SimPlayer, buf: []u8) ?u64 {
        _ = self;
        _ = buf;
        return 180_000; // fake 3:00 track length
    }
    pub fn isPlaying(self: *SimPlayer, buf: []u8) bool {
        _ = buf;
        return self.playing;
    }
};

const Player = if (builtin.os.tag == .windows) @import("mci.zig").Player else SimPlayer;

fn formatMs(buf: []u8, ms: u64) ![]const u8 {
    const total_s = ms / 1000;
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ total_s / 60, total_s % 60 });
}

fn render(out: *std.ArrayList(u8), allocator: std.mem.Allocator, tracks: []const dirscan.Entry, selected: usize, playing_idx: ?usize, player: *Player) !void {
    try tui.clearScreen(out, allocator);

    try tui.moveCursor(out, allocator, 0, 0);
    try tui.setFg(out, allocator, color.active.default_fg);
    try out.appendSlice(allocator, "noirplay");
    try tui.reset(out, allocator);

    var row: usize = 2;
    for (tracks, 0..) |track, i| {
        try tui.moveCursor(out, allocator, row, 0);
        if (i == selected) {
            try tui.setBg(out, allocator, color.active.border);
            try tui.setFg(out, allocator, color.active.default_bg);
        } else if (playing_idx != null and playing_idx.? == i) {
            try tui.setFg(out, allocator, color.active.palette16[2]); // green: now playing
        } else {
            try tui.setFg(out, allocator, color.active.default_fg);
        }
        const marker = if (playing_idx != null and playing_idx.? == i) "> " else "  ";
        try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ marker, track.name }));
        try tui.reset(out, allocator);
        row += 1;
    }

    row += 1;
    try tui.moveCursor(out, allocator, row, 0);
    try tui.setFg(out, allocator, color.active.palette16[5]);
    var pos_buf: [32]u8 = undefined;
    var len_buf: [32]u8 = undefined;
    if (playing_idx != null) {
        const pos_ms = player.positionMs(&pos_buf) orelse 0;
        const len_ms = player.lengthMs(&len_buf) orelse 1;
        var pbuf: [16]u8 = undefined;
        var lbuf: [16]u8 = undefined;
        const pos_str = formatMs(&pbuf, pos_ms) catch "?:??";
        const len_str = formatMs(&lbuf, len_ms) catch "?:??";
        const state = if (player.isPlaying(&pos_buf)) "playing" else "paused";
        try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "[{s}] {s} / {s}", .{ state, pos_str, len_str }));
    } else {
        try out.appendSlice(allocator, "(nothing playing)");
    }
    try tui.reset(out, allocator);

    row += 2;
    try tui.moveCursor(out, allocator, row, 0);
    try tui.setFg(out, allocator, color.active.border);
    try out.appendSlice(allocator, "up/down select, enter play, space play/pause, backspace stop, q quit");
    try tui.reset(out, allocator);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    var raw = tui.RawMode.enable();
    defer raw.disable();

    var cwd_buf: [1024]u8 = undefined;
    const cwd: []const u8 = blk: {
        if (builtin.os.tag == .windows) {
            const win32 = @import("win32.zig");
            var wide_buf: [512]u16 = undefined;
            const len = win32.GetCurrentDirectoryW(wide_buf.len, &wide_buf);
            const n = std.unicode.utf16LeToUtf8(&cwd_buf, wide_buf[0..len]) catch 1;
            break :blk cwd_buf[0..n];
        } else {
            const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
            const len: usize = std.mem.indexOfScalar(u8, &cwd_buf, 0) orelse @intCast(@as(isize, @bitCast(rc)));
            break :blk cwd_buf[0..@intCast(len)];
        }
    };

    const all_entries = try dirscan.listDir(allocator, cwd);
    defer dirscan.freeEntries(allocator, all_entries);

    var tracks: std.ArrayList(dirscan.Entry) = .empty;
    defer tracks.deinit(allocator);
    for (all_entries) |e| {
        if (!e.is_dir and hasAudioExt(e.name)) try tracks.append(allocator, e);
    }

    var selected: usize = 0;
    var playing_idx: ?usize = null;
    var player: Player = .{};
    defer player.close();

    var parser = vt.Parser.init();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    while (true) {
        out.clearRetainingCapacity();
        try render(&out, allocator, tracks.items, selected, playing_idx, &player);
        tui.writeStdout(out.items);

        const key = tui.readKey(&parser) orelse break;
        switch (key) {
            .up => if (selected > 0) {
                selected -= 1;
            },
            .down => if (selected + 1 < tracks.items.len) {
                selected += 1;
            },
            .enter => if (tracks.items.len > 0) {
                var path_buf: [1024]u8 = undefined;
                const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cwd, tracks.items[selected].name });
                if (player.open(path)) {
                    player.play();
                    playing_idx = selected;
                }
            },
            .char => |cp| switch (cp) {
                ' ' => if (playing_idx != null) {
                    var buf: [32]u8 = undefined;
                    if (player.isPlaying(&buf)) player.pause() else player.play();
                },
                'q' => break,
                else => {},
            },
            .backspace => {
                player.stop();
                playing_idx = null;
            },
            else => {},
        }
    }

    try tui.clearScreen(&out, allocator);
    tui.writeStdout("\x1b[2J\x1b[H");
}
