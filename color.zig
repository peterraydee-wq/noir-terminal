//! noirterm/color.zig
//!
//! Color representation for grid cells, plus a `Theme` (16-color
//! palette + default fg/bg) that can be swapped at runtime — see
//! theme.zig for parsing theme files and the built-in theme set.
//!
//! `active` is a plain module-level var, not behind a lock: it's only
//! ever written from the UI thread (in response to a keybinding — see
//! window.zig), and only ever read from the UI thread too (during
//! WM_PAINT). Reader threads never touch color resolution.

const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: Rgb,

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .indexed => |ai| switch (b) {
                .indexed => |bi| ai == bi,
                else => false,
            },
            .rgb => |argb| switch (b) {
                .rgb => |brgb| argb.r == brgb.r and argb.g == brgb.g and argb.b == brgb.b,
                else => false,
            },
        };
    }
};

pub const Theme = struct {
    name: []const u8,
    /// index: 0=black 1=red 2=green 3=yellow 4=blue 5=purple 6=aqua
    /// 7=white, then 8-15 are the "bright" variants.
    palette16: [16]Rgb,
    default_fg: Rgb,
    default_bg: Rgb,
    border: Rgb,
};

/// Everforest Dark (medium contrast), approximate — these hex values
/// were typed from memory; swap in your exact dotfile values via a real
/// theme file (theme.zig) if they need to match precisely.
pub const everforest_dark = Theme{
    .name = "everforest-dark",
    .palette16 = .{
        .{ .r = 0x4B, .g = 0x55, .b = 0x59 }, // 0 black   (bg1-ish)
        .{ .r = 0xE6, .g = 0x7E, .b = 0x80 }, // 1 red
        .{ .r = 0xA7, .g = 0xC0, .b = 0x80 }, // 2 green
        .{ .r = 0xDB, .g = 0xBC, .b = 0x7F }, // 3 yellow
        .{ .r = 0x7F, .g = 0xBB, .b = 0xB3 }, // 4 blue
        .{ .r = 0xD6, .g = 0x99, .b = 0xB6 }, // 5 purple
        .{ .r = 0x83, .g = 0xC0, .b = 0x92 }, // 6 aqua
        .{ .r = 0xD3, .g = 0xC6, .b = 0xAA }, // 7 white   (fg)
        .{ .r = 0x85, .g = 0x92, .b = 0x89 }, // 8 bright black (gray)
        .{ .r = 0xE6, .g = 0x7E, .b = 0x80 }, // 9 bright red
        .{ .r = 0xA7, .g = 0xC0, .b = 0x80 }, // 10 bright green
        .{ .r = 0xDB, .g = 0xBC, .b = 0x7F }, // 11 bright yellow
        .{ .r = 0x7F, .g = 0xBB, .b = 0xB3 }, // 12 bright blue
        .{ .r = 0xD6, .g = 0x99, .b = 0xB6 }, // 13 bright purple
        .{ .r = 0x83, .g = 0xC0, .b = 0x92 }, // 14 bright aqua
        .{ .r = 0xD3, .g = 0xC6, .b = 0xAA }, // 15 bright white
    },
    .default_fg = .{ .r = 0xD3, .g = 0xC6, .b = 0xAA },
    .default_bg = .{ .r = 0x2D, .g = 0x35, .b = 0x3B },
    .border = .{ .r = 0x85, .g = 0x92, .b = 0x89 },
};

/// A real monochrome theme — since "Noir Terminal" is the project's own
/// name, it felt wrong not to actually ship one. Grayscale palette, high
/// contrast.
pub const noir = Theme{
    .name = "noir",
    .palette16 = .{
        .{ .r = 0x1A, .g = 0x1A, .b = 0x1A }, // 0 black
        .{ .r = 0xB0, .g = 0xB0, .b = 0xB0 }, // 1 "red" -> mid gray
        .{ .r = 0xC8, .g = 0xC8, .b = 0xC8 }, // 2 "green" -> light gray
        .{ .r = 0xD8, .g = 0xD8, .b = 0xD8 }, // 3 "yellow" -> lighter gray
        .{ .r = 0x90, .g = 0x90, .b = 0x90 }, // 4 "blue" -> gray
        .{ .r = 0xA0, .g = 0xA0, .b = 0xA0 }, // 5 "purple" -> gray
        .{ .r = 0xC0, .g = 0xC0, .b = 0xC0 }, // 6 "aqua" -> light gray
        .{ .r = 0xE8, .g = 0xE8, .b = 0xE8 }, // 7 white
        .{ .r = 0x50, .g = 0x50, .b = 0x50 }, // 8 bright black
        .{ .r = 0xB0, .g = 0xB0, .b = 0xB0 }, // 9
        .{ .r = 0xC8, .g = 0xC8, .b = 0xC8 }, // 10
        .{ .r = 0xD8, .g = 0xD8, .b = 0xD8 }, // 11
        .{ .r = 0x90, .g = 0x90, .b = 0x90 }, // 12
        .{ .r = 0xA0, .g = 0xA0, .b = 0xA0 }, // 13
        .{ .r = 0xC0, .g = 0xC0, .b = 0xC0 }, // 14
        .{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, // 15 bright white
    },
    .default_fg = .{ .r = 0xE8, .g = 0xE8, .b = 0xE8 },
    .default_bg = .{ .r = 0x0D, .g = 0x0D, .b = 0x0D },
    .border = .{ .r = 0x50, .g = 0x50, .b = 0x50 },
};

pub var active: Theme = everforest_dark;

/// Resolve any Color to a concrete Rgb using the currently active theme.
pub fn resolve(c: Color, is_fg: bool) Rgb {
    return switch (c) {
        .default => if (is_fg) active.default_fg else active.default_bg,
        .rgb => |rgb| rgb,
        .indexed => |i| blk: {
            if (i < 16) break :blk active.palette16[i];
            // 16-231: 6x6x6 color cube: idx = 16 + 36r + 6g + b
            if (i >= 16 and i <= 231) {
                const n = i - 16;
                const r = n / 36;
                const g = (n % 36) / 6;
                const b = n % 6;
                const step = [_]u8{ 0, 95, 135, 175, 215, 255 };
                break :blk Rgb{ .r = step[r], .g = step[g], .b = step[b] };
            }
            // 232-255: grayscale ramp
            const level: u8 = 8 + (i - 232) * 10;
            break :blk Rgb{ .r = level, .g = level, .b = level };
        },
    };
}
