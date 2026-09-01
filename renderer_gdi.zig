//! noirterm/renderer_gdi.zig
//!
//! Draws a Grid via classic GDI (TextOutW + per-run fg/bg via
//! SetTextColor/SetBkColor with SetBkMode(OPAQUE), so each TextOutW call
//! paints its own background — no separate FillRect needed per cell).
//!
//! This is explicitly the INTERIM renderer, not the final one:
//!   - GDI has no text shaping engine. It draws each glyph 1:1 with a
//!     character. It cannot do ligatures, full stop — that needs
//!     DirectWrite (or the legacy Uniscribe/USP10 shaping engine), which
//!     is real COM-API work slated for a later pass.
//!   - No double-width character (CJK/emoji) handling yet — every cell
//!     is assumed one column wide.
//!   - No double-buffering yet, so large repaints may flicker; worth
//!     revisiting once this is confirmed working at all.
//!
//! What it's good for right now: a real, low-risk win32 rendering path
//! (plain C-ABI GDI calls, no COM vtables to get subtly wrong) to prove
//! the window + input + pty loop end to end before taking on GPU/COM risk.

const std = @import("std");
const win32 = @import("win32.zig");
const color = @import("color.zig");
const Grid = @import("grid.zig").Grid;
const Cell = @import("grid.zig").Cell;

fn sameStyle(a: Cell, b: Cell) bool {
    return color.Color.eql(a.fg, b.fg) and color.Color.eql(a.bg, b.bg) and
        std.meta.eql(a.attrs, b.attrs);
}

/// Encodes a codepoint into a UTF-16 buffer, returning the number of
/// u16 units written (1, or 2 for a surrogate pair).
fn encodeUtf16(cp: u21, out: []u16) usize {
    if (cp <= 0xFFFF) {
        out[0] = @intCast(cp);
        return 1;
    }
    const v = cp - 0x10000;
    out[0] = @intCast(0xD800 + (v >> 10));
    out[1] = @intCast(0xDC00 + (v & 0x3FF));
    return 2;
}

pub fn paint(hdc: win32.HDC, grid: *Grid, cell_w: i32, cell_h: i32) void {
    _ = win32.SetBkMode(hdc, win32.OPAQUE);

    var buf16: [512]u16 = undefined;

    var y: usize = 0;
    while (y < grid.rows) : (y += 1) {
        var x: usize = 0;
        while (x < grid.cols) {
            const start = grid.at(x, y).*;
            var run_cells: usize = 0;
            var len16: usize = 0;

            while (x + run_cells < grid.cols and len16 + 2 < buf16.len) {
                const cell = grid.at(x + run_cells, y).*;
                if (!sameStyle(cell, start)) break;
                len16 += encodeUtf16(cell.ch, buf16[len16..]);
                run_cells += 1;
            }
            if (run_cells == 0) {
                // shouldn't happen (first cell always matches itself), but
                // guard against an infinite loop regardless
                run_cells = 1;
            }

            const fg_rgb = color.resolve(start.fg, true);
            const bg_rgb = color.resolve(start.bg, false);
            const use_fg = if (start.attrs.inverse) bg_rgb else fg_rgb;
            const use_bg = if (start.attrs.inverse) fg_rgb else bg_rgb;

            _ = win32.SetTextColor(hdc, win32.rgb(use_fg.r, use_fg.g, use_fg.b));
            _ = win32.SetBkColor(hdc, win32.rgb(use_bg.r, use_bg.g, use_bg.b));
            _ = win32.TextOutW(
                hdc,
                @intCast(x * @as(usize, @intCast(cell_w))),
                @intCast(y * @as(usize, @intCast(cell_h))),
                &buf16,
                @intCast(len16),
            );

            x += run_cells;
        }
    }
}
