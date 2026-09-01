//! Noir Terminal (noirterm) — phase 1 (core) + phase 2 (windowing, Windows-only)
//!
//! Two entirely different code paths by design, not by accident:
//!
//!   - Windows: the real target. Opens an actual window (src/window.zig),
//!     spawns cmd.exe in a ConPTY, and renders the live grid via GDI
//!     (src/renderer_gdi.zig). This has NOT been run — no Windows runtime
//!     in this dev sandbox — see window.zig's header for what that means
//!     for confidence level.
//!   - Everything else (this sandbox's Linux): kept as the original
//!     phase-1 headless proof, since that's what's actually testable
//!     here and it's still useful as a fast platform-agnostic-core
//!     iteration loop (parser/grid changes get tested here before ever
//!     touching the Windows-only rendering path).

const std = @import("std");
const builtin = @import("builtin");
const Pty = @import("pty.zig").Pty;
const Parser = @import("vt/parser.zig").Parser;
const Grid = @import("grid.zig").Grid;

const COLS: usize = 80;
const ROWS: usize = 24;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    if (builtin.os.tag == .windows) {
        const window = @import("window.zig");
        try window.run(allocator);
        return;
    }

    try runHeadlessDemo(allocator);
}

/// The original phase-1 proof: spawn a real shell, feed it ANSI-laden
/// commands, parse the raw output into the grid, dump it as plain text.
/// No window, no GPU — this is the fast-iteration harness for the
/// platform-agnostic parser/grid code, run on whatever this sandbox
/// actually is (Linux).
fn runHeadlessDemo(allocator: std.mem.Allocator) !void {
    const argv: []const []const u8 = &.{"/bin/sh"};

    var pty = try Pty.spawn(allocator, argv, @intCast(COLS), @intCast(ROWS));
    std.debug.print("spawned {s}, pid={d}, on a {d}x{d} pty\n\n", .{ argv[0], pty.child_pid, COLS, ROWS });

    const demo_script =
        "printf '\\033[1;32mHello from Noir Terminal\\033[0m\\n'\n" ++
        "printf '\\033[38;5;208m256-color orange\\033[0m\\n'\n" ++
        "printf 'plain line one\\nplain line two\\n'\n" ++
        "printf 'unicode: caf\\xc3\\xa9 \\xe2\\x86\\x92 \\xe2\\x9c\\x93\\n'\n" ++
        "exit\n";
    _ = pty.write(demo_script);

    var parser = Parser.init();
    var grid = try Grid.init(allocator, COLS, ROWS);

    var raw_byte_count: usize = 0;
    var readbuf: [4096]u8 = undefined;
    while (true) {
        const n = pty.read(&readbuf);
        if (n == 0) break;
        const bytes = readbuf[0..n];
        raw_byte_count += bytes.len;
        for (bytes) |b| {
            const action = parser.feed(b) orelse continue;
            switch (action) {
                .print => |cp| grid.putChar(cp),
                .execute => |byte| grid.execute(byte),
                .csi_dispatch => |csi| grid.applyCsi(csi),
                .esc_dispatch => {},
                .osc_dispatch => {},
                .apc_dispatch => {}, // kitty graphics protocol — see pane.zig for the real handling
            }
        }
    }
    pty.close();

    std.debug.print("read {d} raw bytes from the pty (real ANSI escapes included)\n", .{raw_byte_count});
    std.debug.print("parsed + rendered into the grid, plain-text dump follows:\n", .{});
    std.debug.print("{s}\n", .{"-" ** COLS});

    grid.dumpPlain();

    std.debug.print("{s}\n", .{"-" ** COLS});
    std.debug.print(
        "(colors/attrs were tracked per-cell in grid.cells[i].fg/.bg/.attrs -\n" ++
        " this dump is plain text on purpose; a real renderer is phase 2)\n",
        .{},
    );
}
