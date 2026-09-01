//! noirterm/theme.zig
//!
//! Theme file format — a small hand-rolled INI-style format, not a
//! pulled-in TOML/YAML library, matching this project's zero-dependency
//! pattern elsewhere:
//!
//!   # comments start with '#', blank lines ignored
//!   [palette]
//!   black  = #4B5559
//!   red    = #E67E80
//!   ...all 16 ANSI slots by name (see `slot_names` below)...
//!
//!   [ui]
//!   fg     = #D3C6AA
//!   bg     = #2D353B
//!   border = #859289
//!
//! Any line that doesn't parse (bad section, missing '=', bad hex, an
//! unrecognized key) is simply skipped — a theme file with typos degrades
//! gracefully to "some colors didn't load" rather than refusing to start.
//!
//! This file is pure logic (string parsing only, no file I/O) so it's
//! unit-tested directly, same as layout.zig and kitty_graphics.zig.
//! Loading theme files from disk and wiring the switcher's keybinding
//! live in window.zig, since that part needs real Win32 file APIs this
//! sandbox can't run.

const std = @import("std");
const color = @import("color.zig");
const Rgb = color.Rgb;
const Theme = color.Theme;

const slot_names = [16][]const u8{
    "black",          "red",          "green",          "yellow",
    "blue",           "purple",       "aqua",           "white",
    "bright_black",   "bright_red",   "bright_green",   "bright_yellow",
    "bright_blue",    "bright_purple", "bright_aqua",   "bright_white",
};

pub const ParseError = error{OutOfMemory};

fn parseHexColor(s: []const u8) ?Rgb {
    if (s.len != 7 or s[0] != '#') return null;
    const r = std.fmt.parseInt(u8, s[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, s[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, s[5..7], 16) catch return null;
    return Rgb{ .r = r, .g = g, .b = b };
}

fn slotIndex(name: []const u8) ?usize {
    for (slot_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return null;
}

/// Parses theme file `source` starting from `base` (so a file only
/// overriding a couple of colors still produces a complete, usable
/// Theme). `name` becomes the resulting Theme's name — the caller
/// decides this (typically the filename without extension), since the
/// file format itself doesn't carry a name field.
pub fn parse(allocator: std.mem.Allocator, name: []const u8, source: []const u8, base: Theme) !Theme {
    var theme = base;
    theme.name = try allocator.dupe(u8, name);

    var section: enum { none, palette, ui } = .none;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            const section_name = line[1 .. line.len - 1];
            if (std.mem.eql(u8, section_name, "palette")) {
                section = .palette;
            } else if (std.mem.eql(u8, section_name, "ui")) {
                section = .ui;
            } else {
                section = .none;
            }
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const rgb = parseHexColor(val) orelse continue;

        switch (section) {
            .palette => if (slotIndex(key)) |idx| {
                theme.palette16[idx] = rgb;
            },
            .ui => {
                if (std.mem.eql(u8, key, "fg")) theme.default_fg = rgb;
                if (std.mem.eql(u8, key, "bg")) theme.default_bg = rgb;
                if (std.mem.eql(u8, key, "border")) theme.border = rgb;
            },
            .none => {},
        }
    }
    return theme;
}

/// Serializes a Theme back to the file format — useful for generating a
/// starter file a user can then hand-edit (e.g. "dump the current theme
/// so I have something to tweak").
pub fn serialize(allocator: std.mem.Allocator, theme: Theme) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [128]u8 = undefined;

    try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "# noirterm theme: {s}\n\n[palette]\n", .{theme.name}));
    for (slot_names, 0..) |slot_name, i| {
        const c = theme.palette16[i];
        try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{s} = #{X:0>2}{X:0>2}{X:0>2}\n", .{ slot_name, c.r, c.g, c.b }));
    }
    try out.appendSlice(allocator, "\n[ui]\n");
    try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "fg = #{X:0>2}{X:0>2}{X:0>2}\n", .{ theme.default_fg.r, theme.default_fg.g, theme.default_fg.b }));
    try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "bg = #{X:0>2}{X:0>2}{X:0>2}\n", .{ theme.default_bg.r, theme.default_bg.g, theme.default_bg.b }));
    try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "border = #{X:0>2}{X:0>2}{X:0>2}\n", .{ theme.border.r, theme.border.g, theme.border.b }));
    return out.toOwnedSlice(allocator);
}

/// A small growable registry of themes plus which one is active. The
/// built-ins (everforest-dark, noir) always come first; window.zig
/// appends any it loads from disk on top.
pub const Registry = struct {
    themes: std.ArrayList(Theme) = .empty,
    active_index: usize = 0,

    pub fn initBuiltins(allocator: std.mem.Allocator) !Registry {
        var reg = Registry{};
        try reg.themes.append(allocator, color.everforest_dark);
        try reg.themes.append(allocator, color.noir);
        return reg;
    }

    pub fn add(self: *Registry, allocator: std.mem.Allocator, theme: Theme) !void {
        try self.themes.append(allocator, theme);
    }

    pub fn cycleNext(self: *Registry) void {
        if (self.themes.items.len == 0) return;
        self.active_index = (self.active_index + 1) % self.themes.items.len;
        color.active = self.themes.items[self.active_index];
    }

    pub fn applyActive(self: *Registry) void {
        if (self.themes.items.len == 0) return;
        color.active = self.themes.items[self.active_index];
    }
};

const testing = std.testing;

test "parses hex colors and overrides only what's specified" {
    const source =
        \\# a comment
        \\[palette]
        \\red = #FF0000
        \\
        \\[ui]
        \\bg = #000000
    ;
    const t = try parse(testing.allocator, "test-theme", source, color.everforest_dark);
    defer testing.allocator.free(t.name);

    try testing.expectEqualStrings("test-theme", t.name);
    try testing.expectEqual(Rgb{ .r = 0xFF, .g = 0, .b = 0 }, t.palette16[1]); // red overridden
    try testing.expectEqual(color.everforest_dark.palette16[2], t.palette16[2]); // green untouched
    try testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, t.default_bg); // bg overridden
    try testing.expectEqual(color.everforest_dark.default_fg, t.default_fg); // fg untouched
}

test "malformed lines are skipped, not fatal" {
    const source =
        \\[palette]
        \\red = not-a-color
        \\this line has no equals sign
        \\green = #00FF00
    ;
    const t = try parse(testing.allocator, "t", source, color.everforest_dark);
    defer testing.allocator.free(t.name);
    try testing.expectEqual(color.everforest_dark.palette16[1], t.palette16[1]); // red: bad hex, kept base
    try testing.expectEqual(Rgb{ .r = 0, .g = 0xFF, .b = 0 }, t.palette16[2]); // green: parsed fine
}

test "serialize then parse round-trips a theme" {
    const dumped = try serialize(testing.allocator, color.noir);
    defer testing.allocator.free(dumped);

    const reparsed = try parse(testing.allocator, "noir", dumped, color.everforest_dark);
    defer testing.allocator.free(reparsed.name);

    try testing.expectEqual(color.noir.palette16, reparsed.palette16);
    try testing.expectEqual(color.noir.default_fg, reparsed.default_fg);
    try testing.expectEqual(color.noir.default_bg, reparsed.default_bg);
    try testing.expectEqual(color.noir.border, reparsed.border);
}

test "Registry cycles through built-ins and wraps around" {
    var reg = try Registry.initBuiltins(testing.allocator);
    defer reg.themes.deinit(testing.allocator);

    try testing.expectEqualStrings("everforest-dark", reg.themes.items[reg.active_index].name);
    reg.cycleNext();
    try testing.expectEqualStrings("noir", reg.themes.items[reg.active_index].name);
    reg.cycleNext();
    try testing.expectEqualStrings("everforest-dark", reg.themes.items[reg.active_index].name); // wrapped
}
