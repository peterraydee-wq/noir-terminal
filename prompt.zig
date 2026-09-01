//! noirterm/prompt.zig
//!
//! Composes a starship-style prompt line (ANSI-colored text a shell
//! prints as its prompt) from already-gathered context. Reuses
//! color.Theme rather than its own palette, so the prompt always
//! matches whatever theme is active in the terminal — a small but
//! genuinely nice payoff of building the widget system on top of the
//! theme system instead of the other way around.
//!
//! Pure string composition — no file I/O, no OS calls — so this is
//! fully unit-tested. Gathering the context (prompt_main.zig) is the
//! untested OS-glue half, same split as gitinfo.zig.
//!
//! Segments, ASCII throughout (matching this project's tab-bar/border
//! choices — no Unicode arrows/glyphs that might not render everywhere):
//!   ~/some/path (branch) >        on success
//!   ~/some/path (branch) [1] >    when the last command exited nonzero

const std = @import("std");
const color = @import("color.zig");

pub const Context = struct {
    cwd: []const u8,
    git_branch: ?[]const u8 = null,
    exit_code: u8 = 0,
};

fn appendFg(out: *std.ArrayList(u8), allocator: std.mem.Allocator, rgb: color.Rgb, text: []const u8) !void {
    var buf: [64]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }));
    try out.appendSlice(allocator, text);
    try out.appendSlice(allocator, "\x1b[0m");
}

/// Builds the full prompt line. Caller owns the returned slice.
pub fn compose(allocator: std.mem.Allocator, theme: color.Theme, ctx: Context) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendFg(&out, allocator, theme.palette16[4], ctx.cwd); // path segment: blue slot

    if (ctx.git_branch) |branch| {
        try out.append(allocator, ' ');
        var buf: [256]u8 = undefined;
        const labeled = try std.fmt.bufPrint(&buf, "({s})", .{branch});
        try appendFg(&out, allocator, theme.palette16[5], labeled); // git segment: purple slot
    }

    try out.append(allocator, ' ');
    if (ctx.exit_code == 0) {
        try appendFg(&out, allocator, theme.palette16[2], ">"); // green slot
    } else {
        var buf: [32]u8 = undefined;
        const marker = try std.fmt.bufPrint(&buf, "[{d}] >", .{ctx.exit_code});
        try appendFg(&out, allocator, theme.palette16[1], marker); // red slot
    }

    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

fn stripAnsi(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            while (i < s.len and s[i] != 'm') : (i += 1) {}
            i += 1; // skip the 'm'
            continue;
        }
        try out.append(allocator, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

test "success prompt shows path and a plain '>' marker, no exit code" {
    const line = try compose(testing.allocator, color.everforest_dark, .{ .cwd = "~/proj", .exit_code = 0 });
    defer testing.allocator.free(line);
    const plain = try stripAnsi(testing.allocator, line);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("~/proj >", plain);
}

test "failure prompt shows the exit code" {
    const line = try compose(testing.allocator, color.everforest_dark, .{ .cwd = "~/proj", .exit_code = 127 });
    defer testing.allocator.free(line);
    const plain = try stripAnsi(testing.allocator, line);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("~/proj [127] >", plain);
}

test "git branch segment appears in parens when present" {
    const line = try compose(testing.allocator, color.everforest_dark, .{ .cwd = "~/proj", .git_branch = "main", .exit_code = 0 });
    defer testing.allocator.free(line);
    const plain = try stripAnsi(testing.allocator, line);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("~/proj (main) >", plain);
}

test "colors come from the given theme, not a hardcoded palette" {
    const line = try compose(testing.allocator, color.noir, .{ .cwd = "x", .exit_code = 0 });
    defer testing.allocator.free(line);
    var buf: [32]u8 = undefined;
    const expected_prefix = try std.fmt.bufPrint(&buf, "\x1b[38;2;{d};{d};{d}m", .{
        color.noir.palette16[4].r, color.noir.palette16[4].g, color.noir.palette16[4].b,
    });
    try testing.expect(std.mem.startsWith(u8, line, expected_prefix));
}
