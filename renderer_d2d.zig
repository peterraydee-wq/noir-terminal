//! noirterm/renderer_d2d.zig
//!
//! Draws a Grid via Direct2D + DirectWrite: FillRectangle per
//! same-background run, DrawText per same-foreground run. DirectWrite
//! shapes the text (ligatures, contextual forms) automatically — this
//! is the actual point of this renderer over renderer_gdi.zig, which
//! structurally cannot do that.
//!
//! `paintGrid` draws one pane at a given pixel origin and does NOT call
//! beginDraw/clear/endDraw itself — multiple panes share one D2D frame,
//! so the caller (window.zig) wraps the whole multi-pane draw (plus
//! ASCII borders and the tab bar) in a single begin/clear/end.
//!
//! Still simplified: no double-width character handling yet.

const std = @import("std");
const d2d = @import("d2d.zig");
const color = @import("color.zig");
const Grid = @import("grid.zig").Grid;
const Cell = @import("grid.zig").Cell;

fn sameStyle(a: Cell, b: Cell) bool {
    return color.Color.eql(a.fg, b.fg) and color.Color.eql(a.bg, b.bg) and
        std.meta.eql(a.attrs, b.attrs);
}

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

pub fn toUnit(v: u8) f32 {
    return @as(f32, @floatFromInt(v)) / 255.0;
}

pub fn paintGrid(ctx: *d2d.Context, grid: *Grid, origin_x: f32, origin_y: f32, cell_w: f32, cell_h: f32) void {
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
            if (run_cells == 0) run_cells = 1; // guard, shouldn't trigger

            const fg_rgb = color.resolve(start.fg, true);
            const bg_rgb = color.resolve(start.bg, false);
            const use_fg = if (start.attrs.inverse) bg_rgb else fg_rgb;
            const use_bg = if (start.attrs.inverse) fg_rgb else bg_rgb;

            const left = origin_x + @as(f32, @floatFromInt(x)) * cell_w;
            const top = origin_y + @as(f32, @floatFromInt(y)) * cell_h;
            const right = left + @as(f32, @floatFromInt(run_cells)) * cell_w;
            const bottom = top + cell_h;

            // Background fill for this run — skip if it matches the
            // already-cleared default bg, one fewer draw call per row
            // in the (extremely common) all-default-background case.
            if (!color.Color.eql(start.bg, .default) or start.attrs.inverse) {
                ctx.setBrushColor(toUnit(use_bg.r), toUnit(use_bg.g), toUnit(use_bg.b), 1.0);
                ctx.fillRect(left, top, right, bottom);
            }

            buf16[len16] = 0;
            ctx.setBrushColor(toUnit(use_fg.r), toUnit(use_fg.g), toUnit(use_fg.b), 1.0);
            ctx.drawText(buf16[0..len16 :0], left, top, right, bottom);

            x += run_cells;
        }
    }

    // kitty-graphics image overlay pass, drawn on top of text. NOTE:
    // this re-uploads every placed image as a fresh GPU bitmap on every
    // single paint — correct, but wasteful; caching the bitmap on the
    // ImagePlacement (or in the Pane) instead of recreating it per frame
    // is the obvious next optimization once this is confirmed working
    // at all.
    for (grid.images.items) |placement| {
        const bitmap = ctx.createBitmap(placement.image.width, placement.image.height, placement.image.rgba) orelse continue;
        defer d2d.Context.releaseBitmap(bitmap);
        const left = origin_x + @as(f32, @floatFromInt(placement.cell_x)) * cell_w;
        const top = origin_y + @as(f32, @floatFromInt(placement.cell_y)) * cell_h;
        const right = left + @as(f32, @floatFromInt(placement.image.width));
        const bottom = top + @as(f32, @floatFromInt(placement.image.height));
        ctx.drawBitmap(bitmap, left, top, right, bottom);
    }
}
