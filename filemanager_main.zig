//! noirterm/filemanager_main.zig
//!
//! Standalone file manager binary (`noirfiles`) — phase 8's first half.
//! Built as a genuinely separate program spawned into a pane over its
//! PTY, exactly like `cmd.exe` or `noirprompt` — not a special native
//! rendering mode inside the terminal itself. Reuses the terminal's own
//! VT parser (via tui.zig) for input decoding and color.Theme for
//! styling, so it looks and feels consistent with the terminal without
//! duplicating any of that work.
//!
//! Controls: Up/Down to move the selection, Enter to open a directory
//! (or do nothing on a file — launching an associated app is a
//! reasonable follow-up, not attempted here), Backspace to go up a
//! directory, 'q' to quit.
//!
//! VERIFICATION STATUS: this one's actually been run, on Linux (this
//! sandbox's available platform) — real directory listing, real
//! raw-mode keyboard navigation, real rendering, confirmed working
//! end to end. The Windows-specific pieces (FindFirstFileW-based
//! listing, console-mode raw input) share code with dirscan.zig/
//! tui.zig, whose *logic* is the same either way, but the actual
//! Windows execution path itself is untested like the rest of this
//! project's OS glue.

const std = @import("std");
const builtin = @import("builtin");
const color = @import("color.zig");
const tui = @import("tui.zig");
const dirscan = @import("dirscan.zig");
const vt = @import("vt/parser.zig");

fn render(out: *std.ArrayList(u8), allocator: std.mem.Allocator, cwd: []const u8, entries: []const dirscan.Entry, selected: usize) !void {
    try tui.clearScreen(out, allocator);

    try tui.moveCursor(out, allocator, 0, 0);
    try tui.setFg(out, allocator, color.active.default_fg);
    try out.appendSlice(allocator, cwd);
    try tui.reset(out, allocator);

    var row: usize = 2;
    for (entries, 0..) |entry, i| {
        try tui.moveCursor(out, allocator, row, 0);
        if (i == selected) {
            try tui.setBg(out, allocator, color.active.border);
            try tui.setFg(out, allocator, color.active.default_bg);
        } else if (entry.is_dir) {
            try tui.setFg(out, allocator, color.active.palette16[4]); // blue for dirs
        } else {
            try tui.setFg(out, allocator, color.active.default_fg);
        }
        const marker = if (entry.is_dir) "/" else " ";
        try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ entry.name, marker }));
        try tui.reset(out, allocator);
        row += 1;
    }

    try tui.moveCursor(out, allocator, row + 1, 0);
    try tui.setFg(out, allocator, color.active.border);
    try out.appendSlice(allocator, "up/down move, enter open dir, backspace go up, q quit");
    try tui.reset(out, allocator);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    var raw = tui.RawMode.enable();
    defer raw.disable();

    var cwd_buf: [1024]u8 = undefined;
    var cwd: []u8 = blk: {
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

    var selected: usize = 0;
    var parser = vt.Parser.init();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    while (true) {
        const entries = dirscan.listDir(allocator, cwd) catch blk: {
            const empty: []dirscan.Entry = &[_]dirscan.Entry{};
            break :blk empty;
        };
        std.mem.sort(dirscan.Entry, entries, {}, struct {
            fn lessThan(_: void, a: dirscan.Entry, b: dirscan.Entry) bool {
                if (a.is_dir != b.is_dir) return a.is_dir; // dirs first
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);
        if (selected >= entries.len) selected = if (entries.len == 0) 0 else entries.len - 1;

        out.clearRetainingCapacity();
        try render(&out, allocator, cwd, entries, selected);
        tui.writeStdout(out.items);

        const key = tui.readKey(&parser) orelse break;
        switch (key) {
            .up => if (selected > 0) {
                selected -= 1;
            },
            .down => if (selected + 1 < entries.len) {
                selected += 1;
            },
            .enter => if (entries.len > 0 and entries[selected].is_dir) {
                var new_buf: [1024]u8 = undefined;
                const new_cwd = try std.fmt.bufPrint(&new_buf, "{s}/{s}", .{ cwd, entries[selected].name });
                @memcpy(cwd_buf[0..new_cwd.len], new_cwd);
                cwd = cwd_buf[0..new_cwd.len];
                selected = 0;
            },
            .backspace => {
                if (std.mem.lastIndexOfAny(u8, cwd, "\\/")) |sep| {
                    if (sep > 0) {
                        cwd = cwd_buf[0..sep];
                        selected = 0;
                    }
                }
            },
            .char => |cp| if (cp == 'q') {
                dirscan.freeEntries(allocator, entries);
                break;
            },
            else => {},
        }
        dirscan.freeEntries(allocator, entries);
    }

    try tui.clearScreen(&out, allocator);
    tui.writeStdout("\x1b[2J\x1b[H");
}
