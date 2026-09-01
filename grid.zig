//! noirterm/grid.zig
//!
//! The terminal's screen state: a flat cell buffer plus cursor and current
//! SGR (color/attribute) state. This is deliberately rendering-agnostic —
//! it doesn't know about GPU, GDI, or anything visual. `dumpPlain` exists
//! only so phase 1 can prove the pipeline end-to-end without a renderer.
//!
//! Also holds `images`: kitty-graphics-protocol image placements
//! (decoded RGBA pixel data plus the cell they were placed at). Kept
//! here rather than per-Cell so ordinary text cells don't carry the
//! weight of a rarely-used feature — images are drawn as an overlay
//! pass by whatever renderer is in use, not as part of the cell grid
//! itself.

const std = @import("std");
const color = @import("color.zig");
const vt = @import("vt/parser.zig");
const kitty = @import("kitty_graphics.zig");

pub const Attrs = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,
    strikethrough: bool = false,
    _pad: u2 = 0,
};

pub const Cell = struct {
    ch: u21 = ' ',
    fg: color.Color = .default,
    bg: color.Color = .default,
    attrs: Attrs = .{},
};

pub const ImagePlacement = struct {
    image: kitty.Image,
    cell_x: usize,
    cell_y: usize,
};

pub const Grid = struct {
    allocator: std.mem.Allocator,
    cols: usize,
    rows: usize,
    cells: []Cell,
    cursor_x: usize = 0,
    cursor_y: usize = 0,
    cur_fg: color.Color = .default,
    cur_bg: color.Color = .default,
    cur_attrs: Attrs = .{},
    images: std.ArrayList(ImagePlacement) = .empty,

    pub fn init(allocator: std.mem.Allocator, cols: usize, rows: usize) !Grid {
        const cells = try allocator.alloc(Cell, cols * rows);
        for (cells) |*c| c.* = .{};
        return Grid{ .allocator = allocator, .cols = cols, .rows = rows, .cells = cells };
    }

    pub fn deinit(self: *Grid) void {
        self.allocator.free(self.cells);
        for (self.images.items) |*placement| placement.image.deinit(self.allocator);
        self.images.deinit(self.allocator);
    }

    /// Stores a decoded kitty-graphics image at the current cursor
    /// position. Ownership of `image.rgba` transfers to the Grid (freed
    /// in deinit or when explicitly cleared).
    pub fn placeImage(self: *Grid, image: kitty.Image) !void {
        try self.images.append(self.allocator, .{ .image = image, .cell_x = self.cursor_x, .cell_y = self.cursor_y });
    }

    /// Reallocates the cell buffer for a new size, copying whatever
    /// overlaps between the old and new dimensions (top-left anchored,
    /// like every real terminal's resize behavior) and clearing the
    /// rest. Needed once panes can have independent sizes (phase 4) —
    /// before that, the grid was created once and never resized.
    pub fn resize(self: *Grid, new_cols: usize, new_rows: usize) !void {
        if (new_cols == self.cols and new_rows == self.rows) return;
        const new_cells = try self.allocator.alloc(Cell, new_cols * new_rows);
        for (new_cells) |*c| c.* = .{};

        const copy_cols = @min(self.cols, new_cols);
        const copy_rows = @min(self.rows, new_rows);
        var y: usize = 0;
        while (y < copy_rows) : (y += 1) {
            const old_start = y * self.cols;
            const new_start = y * new_cols;
            @memcpy(new_cells[new_start .. new_start + copy_cols], self.cells[old_start .. old_start + copy_cols]);
        }

        self.allocator.free(self.cells);
        self.cells = new_cells;
        self.cols = new_cols;
        self.rows = new_rows;
        self.cursor_x = @min(self.cursor_x, new_cols -| 1);
        self.cursor_y = @min(self.cursor_y, new_rows -| 1);
    }

    pub fn at(self: *Grid, x: usize, y: usize) *Cell {
        return &self.cells[y * self.cols + x];
    }

    fn clearRow(self: *Grid, y: usize, from: usize, to: usize) void {
        var x = from;
        while (x < to) : (x += 1) self.at(x, y).* = .{};
    }

    fn scrollUp(self: *Grid) void {
        var y: usize = 0;
        while (y < self.rows - 1) : (y += 1) {
            const dst = y * self.cols;
            const src = (y + 1) * self.cols;
            std.mem.copyForwards(Cell, self.cells[dst .. dst + self.cols], self.cells[src .. src + self.cols]);
        }
        self.clearRow(self.rows - 1, 0, self.cols);
    }

    pub fn newline(self: *Grid) void {
        if (self.cursor_y + 1 >= self.rows) {
            self.scrollUp();
        } else {
            self.cursor_y += 1;
        }
    }

    pub fn carriageReturn(self: *Grid) void {
        self.cursor_x = 0;
    }

    pub fn backspace(self: *Grid) void {
        if (self.cursor_x > 0) self.cursor_x -= 1;
    }

    pub fn putChar(self: *Grid, ch: u21) void {
        if (self.cursor_x >= self.cols) {
            self.carriageReturn();
            self.newline();
        }
        const cell = self.at(self.cursor_x, self.cursor_y);
        cell.* = .{ .ch = ch, .fg = self.cur_fg, .bg = self.cur_bg, .attrs = self.cur_attrs };
        self.cursor_x += 1;
    }

    pub fn execute(self: *Grid, byte: u8) void {
        switch (byte) {
            '\n' => self.newline(),
            '\r' => self.carriageReturn(),
            0x08 => self.backspace(),
            '\t' => {
                const next_tab = ((self.cursor_x / 8) + 1) * 8;
                self.cursor_x = @min(next_tab, self.cols - 1);
            },
            else => {},
        }
    }

    fn param(params: []const i64, i: usize, default: i64) i64 {
        if (i >= params.len) return default;
        if (params[i] == 0) return default;
        return params[i];
    }

    pub fn applyCsi(self: *Grid, csi: vt.CsiDispatch) void {
        switch (csi.final) {
            'H', 'f' => {
                const row = param(csi.params, 0, 1);
                const col = param(csi.params, 1, 1);
                const max_row: i64 = @intCast(self.rows - 1);
                const max_col: i64 = @intCast(self.cols - 1);
                self.cursor_y = @intCast(std.math.clamp(row - 1, 0, max_row));
                self.cursor_x = @intCast(std.math.clamp(col - 1, 0, max_col));
            },
            'A' => self.cursor_y -|= @as(usize, @intCast(param(csi.params, 0, 1))),
            'B' => self.cursor_y = @min(self.cursor_y + @as(usize, @intCast(param(csi.params, 0, 1))), self.rows - 1),
            'C' => self.cursor_x = @min(self.cursor_x + @as(usize, @intCast(param(csi.params, 0, 1))), self.cols - 1),
            'D' => self.cursor_x -|= @as(usize, @intCast(param(csi.params, 0, 1))),
            'J' => self.eraseInDisplay(param(csi.params, 0, 0)),
            'K' => self.eraseInLine(param(csi.params, 0, 0)),
            'm' => self.applySgr(csi.params),
            else => {}, // scroll regions, DECSET/RESET, cursor visibility, etc. land here in later phases
        }
    }

    fn eraseInLine(self: *Grid, mode: i64) void {
        const y = self.cursor_y;
        switch (mode) {
            0 => self.clearRow(y, self.cursor_x, self.cols),
            1 => self.clearRow(y, 0, @min(self.cursor_x + 1, self.cols)),
            2 => self.clearRow(y, 0, self.cols),
            else => {},
        }
    }

    fn eraseInDisplay(self: *Grid, mode: i64) void {
        switch (mode) {
            0 => {
                self.eraseInLine(0);
                var y = self.cursor_y + 1;
                while (y < self.rows) : (y += 1) self.clearRow(y, 0, self.cols);
            },
            1 => {
                self.eraseInLine(1);
                var y: usize = 0;
                while (y < self.cursor_y) : (y += 1) self.clearRow(y, 0, self.cols);
            },
            2, 3 => {
                for (self.cells) |*c| c.* = .{};
                self.cursor_x = 0;
                self.cursor_y = 0;
            },
            else => {},
        }
    }

    fn applySgr(self: *Grid, params: []const i64) void {
        if (params.len == 0) {
            self.cur_fg = .default;
            self.cur_bg = .default;
            self.cur_attrs = .{};
            return;
        }
        var i: usize = 0;
        while (i < params.len) : (i += 1) {
            const p = params[i];
            switch (p) {
                0 => {
                    self.cur_fg = .default;
                    self.cur_bg = .default;
                    self.cur_attrs = .{};
                },
                1 => self.cur_attrs.bold = true,
                2 => self.cur_attrs.dim = true,
                3 => self.cur_attrs.italic = true,
                4 => self.cur_attrs.underline = true,
                7 => self.cur_attrs.inverse = true,
                9 => self.cur_attrs.strikethrough = true,
                22 => {
                    self.cur_attrs.bold = false;
                    self.cur_attrs.dim = false;
                },
                23 => self.cur_attrs.italic = false,
                24 => self.cur_attrs.underline = false,
                27 => self.cur_attrs.inverse = false,
                29 => self.cur_attrs.strikethrough = false,
                30...37 => self.cur_fg = .{ .indexed = @intCast(p - 30) },
                38 => i += self.parseExtendedColor(params[i..], true),
                39 => self.cur_fg = .default,
                40...47 => self.cur_bg = .{ .indexed = @intCast(p - 40) },
                48 => i += self.parseExtendedColor(params[i..], false),
                49 => self.cur_bg = .default,
                90...97 => self.cur_fg = .{ .indexed = @intCast(p - 90 + 8) },
                100...107 => self.cur_bg = .{ .indexed = @intCast(p - 100 + 8) },
                else => {},
            }
        }
    }

    /// Parses `;5;n` (256-color) or `;2;r;g;b` (truecolor) following a 38/48
    /// code. `rest` starts at the 38/48 element itself. Returns how many
    /// extra elements were consumed (0 if the form wasn't recognized).
    fn parseExtendedColor(self: *Grid, rest: []const i64, is_fg: bool) usize {
        if (rest.len >= 3 and rest[1] == 5) {
            const idx: u8 = @intCast(std.math.clamp(rest[2], 0, 255));
            if (is_fg) self.cur_fg = .{ .indexed = idx } else self.cur_bg = .{ .indexed = idx };
            return 2;
        }
        if (rest.len >= 5 and rest[1] == 2) {
            const c = color.Rgb{
                .r = @intCast(std.math.clamp(rest[2], 0, 255)),
                .g = @intCast(std.math.clamp(rest[3], 0, 255)),
                .b = @intCast(std.math.clamp(rest[4], 0, 255)),
            };
            if (is_fg) self.cur_fg = .{ .rgb = c } else self.cur_bg = .{ .rgb = c };
            return 4;
        }
        return 0;
    }

    /// Debug/proof-of-pipeline dump: plain text, no colors, via
    /// std.debug.print (portable — works the same on every target).
    /// Real rendering (GPU glyph atlas etc.) is a later phase; this only
    /// exists so phase 1 can prove the pipeline without a renderer.
    pub fn dumpPlain(self: *Grid) void {
        var line_buf: [1024]u8 = undefined;
        var y: usize = 0;
        while (y < self.rows) : (y += 1) {
            var pos: usize = 0;
            var x: usize = 0;
            while (x < self.cols) : (x += 1) {
                var cbuf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(self.at(x, y).ch, &cbuf) catch 1;
                if (pos + len < line_buf.len) {
                    @memcpy(line_buf[pos .. pos + len], cbuf[0..len]);
                    pos += len;
                }
            }
            std.debug.print("{s}\n", .{line_buf[0..pos]});
        }
    }
};

test "resize preserves overlapping content, top-left anchored" {
    var g = try Grid.init(std.testing.allocator, 4, 2);
    defer g.deinit();
    g.putChar('A');
    g.putChar('B');
    g.newline();
    g.carriageReturn();
    g.putChar('C');

    try g.resize(2, 3); // shrink cols, grow rows
    try std.testing.expectEqual(@as(u21, 'A'), g.at(0, 0).ch);
    try std.testing.expectEqual(@as(u21, 'B'), g.at(1, 0).ch);
    try std.testing.expectEqual(@as(u21, 'C'), g.at(0, 1).ch);
    try std.testing.expectEqual(@as(u21, ' '), g.at(0, 2).ch); // new row cleared

    try g.resize(5, 5); // grow both dims
    try std.testing.expectEqual(@as(u21, 'A'), g.at(0, 0).ch);
    try std.testing.expectEqual(@as(u21, ' '), g.at(4, 4).ch);
}

test "resize clamps cursor into new bounds" {
    var g = try Grid.init(std.testing.allocator, 10, 10);
    defer g.deinit();
    g.cursor_x = 9;
    g.cursor_y = 9;
    try g.resize(3, 3);
    try std.testing.expect(g.cursor_x < 3);
    try std.testing.expect(g.cursor_y < 3);
}

test "SGR truecolor sets rgb fg" {
    var g = try Grid.init(std.testing.allocator, 4, 4);
    defer g.deinit();
    const params = [_]i64{ 38, 2, 10, 20, 30 };
    g.applySgr(&params);
    switch (g.cur_fg) {
        .rgb => |rgb| {
            try std.testing.expectEqual(@as(u8, 10), rgb.r);
            try std.testing.expectEqual(@as(u8, 20), rgb.g);
            try std.testing.expectEqual(@as(u8, 30), rgb.b);
        },
        else => return error.TestExpectedRgb,
    }
}
