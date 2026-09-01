//! noirterm/gitinfo.zig
//!
//! Minimal git-branch detection for the prompt widget — reads
//! `.git/HEAD` directly rather than shelling out to `git.exe`, keeping
//! the prompt tool fast and dependency-free (matching this project's
//! pattern elsewhere). Branch name only — no dirty/staged/ahead-behind
//! status; that needs walking the index and is real scope for a
//! follow-up, not squeezed in here.

const std = @import("std");
const builtin = @import("builtin");

/// Parses the contents of a `.git/HEAD` file. Pure logic, unit-tested.
/// Returns the branch name for a normal HEAD (`ref: refs/heads/<name>`),
/// a short commit hash for a detached HEAD, or null for empty/malformed
/// content.
pub fn parseHead(contents: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, contents, " \n\r\t");
    if (trimmed.len == 0) return null;
    const ref_prefix = "ref: refs/heads/";
    if (std.mem.startsWith(u8, trimmed, ref_prefix)) {
        const name = trimmed[ref_prefix.len..];
        return if (name.len > 0) name else null;
    }
    // Detached HEAD: a raw commit hash (40 hex chars for sha1, 64 for
    // the newer sha256 repos) — show a short prefix, like `git status`
    // does, rather than the whole thing.
    if (trimmed.len >= 7 and isHex(trimmed)) return trimmed[0..7];
    return null;
}

fn isHex(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn readSmallFile(path: [:0]const u8, buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        const win32 = @import("win32.zig");
        var wide_buf: [512]u16 = undefined;
        const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, path) catch return null;
        if (wide_len >= wide_buf.len) return null;
        wide_buf[wide_len] = 0;
        const file = win32.CreateFileW(wide_buf[0..wide_len :0].ptr, win32.GENERIC_READ, win32.FILE_SHARE_READ, null, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, null);
        if (file == win32.INVALID_HANDLE_VALUE) return null;
        defer win32.CloseHandle(file);
        var read: win32.DWORD = 0;
        if (win32.ReadFile(file, buf.ptr, @intCast(buf.len), &read, null) == win32.BOOL.FALSE) return null;
        return buf[0..read];
    } else {
        const linux = std.os.linux;
        const fd_rc = linux.open(path.ptr, .{ .ACCMODE = .RDONLY }, 0);
        if (@as(isize, @bitCast(fd_rc)) < 0) return null;
        const fd: i32 = @intCast(fd_rc);
        defer _ = linux.close(fd);
        const n = linux.read(fd, buf.ptr, buf.len);
        if (@as(isize, @bitCast(n)) < 0) return null;
        return buf[0..n];
    }
}

/// Walks upward from `start_dir` looking for a `.git` directory, reads
/// its HEAD file, and returns the branch name (allocator-owned). Returns
/// null if none is found or on any I/O error — "not a git repo" and
/// "couldn't read it" are both just "don't show a branch", not
/// something worth failing the whole prompt over.
pub fn findBranch(allocator: std.mem.Allocator, start_dir: []const u8) ?[]const u8 {
    var dir = std.mem.trimEnd(u8, start_dir, "\\/");
    var path_buf: [4096]u8 = undefined;
    var file_buf: [512]u8 = undefined;

    while (true) {
        const head_path_slice = std.fmt.bufPrint(&path_buf, "{s}/.git/HEAD", .{dir}) catch return null;
        const head_path: [:0]const u8 = blk: {
            path_buf[head_path_slice.len] = 0;
            break :blk path_buf[0..head_path_slice.len :0];
        };
        if (readSmallFile(head_path, &file_buf)) |contents| {
            const branch = parseHead(contents) orelse return null;
            return allocator.dupe(u8, branch) catch null;
        }
        const sep = std.mem.lastIndexOfAny(u8, dir, "\\/") orelse return null;
        if (sep == 0) return null;
        dir = dir[0..sep];
    }
}

const testing = std.testing;

test "parses a normal branch HEAD" {
    try testing.expectEqualStrings("main", parseHead("ref: refs/heads/main\n").?);
    try testing.expectEqualStrings("feature/thing", parseHead("ref: refs/heads/feature/thing\n").?);
}

test "parses a detached HEAD to a short hash" {
    const sha = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678\n";
    try testing.expectEqualStrings("a1b2c3d", parseHead(sha).?);
}

test "rejects empty or malformed content" {
    try testing.expect(parseHead("") == null);
    try testing.expect(parseHead("   \n") == null);
    try testing.expect(parseHead("ref: refs/heads/") == null);
    try testing.expect(parseHead("not a hash and not a ref") == null);
}
