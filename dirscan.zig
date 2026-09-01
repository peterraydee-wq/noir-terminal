//! noirterm/dirscan.zig
//!
//! Directory listing for the file manager and music player's track
//! list. Windows side uses FindFirstFileW/FindNextFileW/FindClose —
//! WIN32_FIND_DATAW's field layout was cross-checked against the real
//! mingw-w64 headers via @cImport (same technique used for d2d.zig)
//! rather than transcribed from memory, since a wrong field order here
//! would silently misread file names/attributes rather than fail to
//! compile. Linux side uses the getdents64 syscall directly, purely so
//! this is testable in this dev sandbox.

const std = @import("std");
const builtin = @import("builtin");
const win32 = if (builtin.os.tag == .windows) @import("win32.zig") else struct {};

pub const Entry = struct {
    name: []const u8, // allocator-owned
    is_dir: bool,
};

pub fn listDir(allocator: std.mem.Allocator, path: []const u8) ![]Entry {
    return if (builtin.os.tag == .windows) listDirWindows(allocator, path) else listDirLinux(allocator, path);
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| allocator.free(e.name);
    allocator.free(entries);
}

const FILETIME = extern struct {
    dwLowDateTime: u32 = 0,
    dwHighDateTime: u32 = 0,
};

const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: u32 = 0,
    ftCreationTime: FILETIME = .{},
    ftLastAccessTime: FILETIME = .{},
    ftLastWriteTime: FILETIME = .{},
    nFileSizeHigh: u32 = 0,
    nFileSizeLow: u32 = 0,
    dwReserved0: u32 = 0,
    dwReserved1: u32 = 0,
    cFileName: [260]u16 = [_]u16{0} ** 260,
    cAlternateFileName: [14]u16 = [_]u16{0} ** 14,
};

const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;

extern "kernel32" fn FindFirstFileW(lpFileName: win32.LPCWSTR, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) win32.HANDLE;
extern "kernel32" fn FindNextFileW(hFindFile: win32.HANDLE, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) win32.BOOL;
extern "kernel32" fn FindClose(hFindFile: win32.HANDLE) callconv(.winapi) win32.BOOL;

fn listDirWindows(allocator: std.mem.Allocator, path: []const u8) ![]Entry {
    var wide_buf: [1024]u16 = undefined;
    var utf8_buf: [1024]u8 = undefined;
    const glob = try std.fmt.bufPrint(&utf8_buf, "{s}\\*", .{path});
    const wide_len = try std.unicode.utf8ToUtf16Le(&wide_buf, glob);
    if (wide_len >= wide_buf.len) return error.PathTooLong;
    wide_buf[wide_len] = 0;

    var list: std.ArrayList(Entry) = .empty;
    errdefer freeEntries(allocator, list.toOwnedSlice(allocator) catch &.{});

    var find_data: WIN32_FIND_DATAW = .{};
    const handle = FindFirstFileW(wide_buf[0..wide_len :0].ptr, &find_data);
    if (handle == win32.INVALID_HANDLE_VALUE) return list.toOwnedSlice(allocator);
    defer _ = FindClose(handle);

    while (true) {
        const name_len = std.mem.indexOfScalar(u16, &find_data.cFileName, 0) orelse find_data.cFileName.len;
        var name_utf8_buf: [520]u8 = undefined;
        const name_utf8_len = std.unicode.utf16LeToUtf8(&name_utf8_buf, find_data.cFileName[0..name_len]) catch 0;
        const name_utf8 = name_utf8_buf[0..name_utf8_len];
        if (!std.mem.eql(u8, name_utf8, ".") and !std.mem.eql(u8, name_utf8, "..")) {
            try list.append(allocator, .{
                .name = try allocator.dupe(u8, name_utf8),
                .is_dir = (find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0,
            });
        }
        if (FindNextFileW(handle, &find_data) == win32.BOOL.FALSE) break;
    }
    return list.toOwnedSlice(allocator);
}

fn listDirLinux(allocator: std.mem.Allocator, path: []const u8) ![]Entry {
    const linux = std.os.linux;
    var path_buf: [1024]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    const fd_rc = linux.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (@as(isize, @bitCast(fd_rc)) < 0) return error.OpenDirFailed;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);

    var list: std.ArrayList(Entry) = .empty;
    errdefer freeEntries(allocator, list.toOwnedSlice(allocator) catch &.{});

    var dirent_buf: [4096]u8 = undefined;
    while (true) {
        const n = linux.getdents64(fd, &dirent_buf, dirent_buf.len);
        if (@as(isize, @bitCast(n)) <= 0) break;
        var pos: usize = 0;
        while (pos < n) {
            const d: *align(1) linux.dirent64 = @ptrCast(&dirent_buf[pos]);
            const name_ptr: [*:0]const u8 = @ptrCast(&d.name);
            const name = std.mem.sliceTo(name_ptr, 0);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                // DT_DIR = 4 (dirent64.type); good enough without a
                // stat() fallback for DT_UNKNOWN filesystems.
                try list.append(allocator, .{
                    .name = try allocator.dupe(u8, name),
                    .is_dir = d.type == 4,
                });
            }
            pos += d.reclen;
        }
    }
    return list.toOwnedSlice(allocator);
}
