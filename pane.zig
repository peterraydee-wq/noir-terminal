//! noirterm/pane.zig
//!
//! One terminal session: its own PTY, parser, grid, and a background
//! reader thread. A tab holds one or more panes arranged by a
//! layout.Layout; splitting a tab just means spawning another Pane and
//! adding it to the tree.

const std = @import("std");
const Pty = @import("pty.zig").Pty;
const Parser = @import("vt/parser.zig").Parser;
const Grid = @import("grid.zig").Grid;
const win32 = @import("win32.zig");
const kitty = @import("kitty_graphics.zig");

// std.Thread.Mutex doesn't exist in this Zig version (Mutex moved under
// the new async std.Io, which needs an Io context we don't otherwise
// use) — a tiny hand-rolled spinlock is simpler and plenty for this
// low-contention case (one reader thread posting occasionally, one UI
// thread draining).
pub const SpinLock = struct {
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

pub const Pane = struct {
    pty: Pty,
    parser: Parser = Parser.init(),
    grid: Grid,
    buf_lock: SpinLock = .{},
    pty_buf: std.ArrayList(u8) = .empty,

    pub fn create(allocator: std.mem.Allocator, argv: []const []const u8, cols: usize, rows: usize) !*Pane {
        const pty = try Pty.spawn(allocator, argv, @intCast(cols), @intCast(rows));
        const grid = try Grid.init(allocator, cols, rows);
        const pane = try allocator.create(Pane);
        pane.* = .{ .pty = pty, .grid = grid };
        return pane;
    }

    /// Starts the background thread that drains this pane's PTY. The
    /// pane's own pointer is sent back via PostMessageW's lParam, so the
    /// message handler can drain exactly this pane directly — this stays
    /// correct even if tabs are reordered/closed later, unlike an index
    /// into some list that could shift out from under it.
    pub fn startReaderThread(self: *Pane, hwnd: win32.HWND) !void {
        const ctx = try std.heap.page_allocator.create(ReaderCtx);
        ctx.* = .{ .pane = self, .hwnd = hwnd };
        _ = try std.Thread.spawn(.{}, readerThreadFn, .{ctx});
    }

    const ReaderCtx = struct {
        pane: *Pane,
        hwnd: win32.HWND,
    };

    fn readerThreadFn(ctx: *ReaderCtx) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = ctx.pane.pty.read(&buf);
            if (n == 0) break; // child exited
            ctx.pane.buf_lock.lock();
            ctx.pane.pty_buf.appendSlice(std.heap.page_allocator, buf[0..n]) catch {};
            ctx.pane.buf_lock.unlock();
            const lparam: win32.LPARAM = @bitCast(@as(isize, @bitCast(@intFromPtr(ctx.pane))));
            _ = win32.PostMessageW(ctx.hwnd, win32.WM_APP_PTY_DATA, 0, lparam);
        }
    }

    /// Feeds any buffered PTY output through the parser into the grid.
    /// Call this from the UI thread in response to WM_APP_PTY_DATA.
    pub fn drain(self: *Pane) void {
        self.buf_lock.lock();
        for (self.pty_buf.items) |b| {
            const action = self.parser.feed(b) orelse continue;
            switch (action) {
                .print => |cp| self.grid.putChar(cp),
                .execute => |byte| self.grid.execute(byte),
                .csi_dispatch => |csi| self.grid.applyCsi(csi),
                .esc_dispatch => {},
                .osc_dispatch => {},
                .apc_dispatch => |payload| self.handleApc(payload),
            }
        }
        self.pty_buf.clearRetainingCapacity();
        self.buf_lock.unlock();
    }

    /// kitty graphics protocol lives on APC — anything else falls
    /// through kitty_graphics.parse's "not graphics" null case and is
    /// silently ignored, matching the parser's own C0/DCS handling.
    fn handleApc(self: *Pane, payload: []const u8) void {
        var cmd = kitty.parse(self.grid.allocator, payload) orelse return;
        if (cmd.image) |img| {
            self.grid.placeImage(img) catch {
                var mutable_img = img;
                mutable_img.deinit(self.grid.allocator); // placement failed, don't leak
            };
        }
        _ = &cmd;
    }

    pub fn resize(self: *Pane, cols: usize, rows: usize) !void {
        if (cols == self.grid.cols and rows == self.grid.rows) return;
        try self.grid.resize(cols, rows);
        self.pty.resize(@intCast(cols), @intCast(rows));
    }

    pub fn write(self: *Pane, bytes: []const u8) void {
        _ = self.pty.write(bytes);
    }
};
