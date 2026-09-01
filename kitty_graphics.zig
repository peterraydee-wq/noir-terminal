//! noirterm/kitty_graphics.zig
//!
//! Parses the kitty graphics protocol's APC payload:
//! `G<key>=<val>,<key>=<val>,...;<base64 payload>`
//! (the leading `G` and the surrounding `ESC _ ... ESC \` are already
//! stripped by the time this sees it — vt/parser.zig's apc_dispatch
//! action hands over everything between `ESC _` and the terminator, and
//! the `G` is kitty's own convention marking "this APC is graphics").
//!
//! Scope, deliberately: this is a minimal viable slice of a large
//! protocol, not a full implementation. Supported:
//!   - Direct transmission only (t=d) — no file-based (t=f) or shared-
//!     memory (t=s/t=t) transmission media.
//!   - Raw pixel formats only: f=32 (RGBA) and f=24 (RGB, converted to
//!     RGBA with alpha=255). No f=100 (PNG) — decoding PNG would mean
//!     pulling in either a PNG decoder or Windows Imaging Component
//!     (another large COM surface), which is out of scope here.
//!   - No chunked transmission (the `m=1` continuation flag) — an
//!     image's whole base64 payload has to arrive in one APC sequence,
//!     bounded by vt/parser.zig's MAX_APC (256 KiB, so roughly 192 KiB
//!     of raw pixel data after base64 overhead).
//!   - No animation frames, no z-index compositing, no deletion
//!     commands (a=d) — an unrecognized/unsupported `a` value just
//!     results in `image = null` in the returned Command.

const std = @import("std");

pub const Image = struct {
    width: u32,
    height: u32,
    rgba: []u8, // allocator-owned, width*height*4 bytes, caller frees

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.rgba);
    }
};

pub const Command = struct {
    action: u8,
    image_id: ?u32,
    image: ?Image,
};

fn decodeImage(allocator: std.mem.Allocator, format: u32, width: u32, height: u32, b64: []const u8) ?Image {
    if (width == 0 or height == 0) return null;
    if (format != 32 and format != 24) return null; // only raw RGBA/RGB supported

    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(b64) catch return null;
    const bytes_per_pixel: usize = if (format == 32) 4 else 3;
    const expected_len = @as(usize, width) * @as(usize, height) * bytes_per_pixel;
    if (decoded_len < expected_len) return null; // truncated or malformed

    const raw = allocator.alloc(u8, decoded_len) catch return null;
    defer allocator.free(raw);
    decoder.decode(raw, b64) catch return null;

    const rgba = allocator.alloc(u8, @as(usize, width) * @as(usize, height) * 4) catch return null;
    if (format == 32) {
        @memcpy(rgba, raw[0..rgba.len]);
    } else {
        var i: usize = 0;
        var j: usize = 0;
        while (i < expected_len) : (i += 3) {
            rgba[j] = raw[i];
            rgba[j + 1] = raw[i + 1];
            rgba[j + 2] = raw[i + 2];
            rgba[j + 3] = 255;
            j += 4;
        }
    }
    return Image{ .width = width, .height = height, .rgba = rgba };
}

/// Returns null if `apc_payload` isn't a kitty graphics command at all
/// (doesn't start with 'G') — anything else (unrecognized action,
/// unsupported format, bad base64) still returns a Command, just with
/// `image = null`, so the caller can distinguish "not graphics" from
/// "graphics, but we couldn't decode it".
pub fn parse(allocator: std.mem.Allocator, apc_payload: []const u8) ?Command {
    if (apc_payload.len == 0 or apc_payload[0] != 'G') return null;
    const rest = apc_payload[1..];
    const semi = std.mem.indexOfScalar(u8, rest, ';');
    const control_str = if (semi) |s| rest[0..s] else rest;
    const payload_b64 = if (semi) |s| rest[s + 1 ..] else "";

    var action: u8 = 't'; // spec default when `a` is omitted
    var format: u32 = 32; // spec default when `f` is omitted
    var width: u32 = 0;
    var height: u32 = 0;
    var image_id: ?u32 = null;
    var medium: u8 = 'd'; // spec default when `t` is omitted

    var it = std.mem.splitScalar(u8, control_str, ',');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const key = kv[0..eq];
        const val = kv[eq + 1 ..];
        if (val.len == 0) continue;
        if (std.mem.eql(u8, key, "a")) {
            action = val[0];
        } else if (std.mem.eql(u8, key, "f")) {
            format = std.fmt.parseInt(u32, val, 10) catch format;
        } else if (std.mem.eql(u8, key, "s")) {
            width = std.fmt.parseInt(u32, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "v")) {
            height = std.fmt.parseInt(u32, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "i")) {
            image_id = std.fmt.parseInt(u32, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "t")) {
            medium = val[0];
        }
    }

    var image: ?Image = null;
    if ((action == 'T' or action == 't') and medium == 'd') {
        image = decodeImage(allocator, format, width, height, payload_b64);
    }

    return Command{ .action = action, .image_id = image_id, .image = image };
}

const testing = std.testing;

test "parses a tiny 1x1 RGBA image (direct transmission)" {
    // one red pixel, full alpha
    const raw = [_]u8{ 255, 0, 0, 255 };
    var b64buf: [64]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64buf, &raw);

    var apc_buf: [128]u8 = undefined;
    const apc = try std.fmt.bufPrint(&apc_buf, "Ga=T,f=32,s=1,v=1;{s}", .{b64});

    var cmd = parse(testing.allocator, apc).?;
    defer if (cmd.image) |*img| img.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 'T'), cmd.action);
    try testing.expect(cmd.image != null);
    try testing.expectEqual(@as(u32, 1), cmd.image.?.width);
    try testing.expectEqual(@as(u32, 1), cmd.image.?.height);
    try testing.expectEqualSlices(u8, &raw, cmd.image.?.rgba);
}

test "converts RGB (f=24) to RGBA with full alpha" {
    const raw = [_]u8{ 10, 20, 30 }; // one RGB pixel
    var b64buf: [64]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64buf, &raw);

    var apc_buf: [128]u8 = undefined;
    const apc = try std.fmt.bufPrint(&apc_buf, "Ga=T,f=24,s=1,v=1;{s}", .{b64});

    var cmd = parse(testing.allocator, apc).?;
    defer if (cmd.image) |*img| img.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, cmd.image.?.rgba);
}

test "non-graphics APC payload returns null" {
    try testing.expect(parse(testing.allocator, "not kitty graphics") == null);
}

test "unsupported format yields a Command with no image, not a crash" {
    var apc_buf: [128]u8 = undefined;
    const apc = try std.fmt.bufPrint(&apc_buf, "Ga=T,f=100,s=4,v=4;AAAA", .{}); // f=100 = PNG, unsupported
    const cmd = parse(testing.allocator, apc).?;
    try testing.expect(cmd.image == null);
}

test "image_id is parsed when present" {
    var apc_buf: [128]u8 = undefined;
    const apc = try std.fmt.bufPrint(&apc_buf, "Ga=t,i=42,f=32,s=1,v=1;AAAAAA==", .{});
    var cmd = parse(testing.allocator, apc).?;
    defer if (cmd.image) |*img| img.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 42), cmd.image_id.?);
}
