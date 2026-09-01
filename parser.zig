//! noirterm/vt/parser.zig
//!
//! A from-scratch implementation of the standard terminal escape-sequence
//! state machine (the same shape of automaton documented at the well-known
//! "DEC ANSI parser" state diagram, and used — each with their own
//! independent implementation — by every serious terminal emulator).
//! No code here is copied from any existing terminal's source; this is a
//! straightforward implementation of the public ECMA-48 / ANSI X3.64
//! control-sequence grammar.
//!
//! DCS (Device Control String) is stubbed to "swallow until terminator"
//! so it doesn't corrupt the rest of the stream — Sixel rides on DCS and
//! isn't in scope. APC (Application Program Command, `ESC _ ... ESC \`)
//! IS captured now (not just swallowed): kitty's graphics protocol rides
//! on APC (`ESC _ G ... ESC \`), and kitty_graphics.zig parses whatever
//! comes out of `Action.apc_dispatch`. PM (Privacy Message, `ESC ^`) is
//! still just swallowed — nothing meaningful rides on it here.

const std = @import("std");

pub const MAX_PARAMS = 32;
const MAX_INTERMEDIATES = 4;
const MAX_OSC = 2048;
// Kitty image payloads are base64, so this bounds transferred image size
// to roughly 3/4 of this in raw bytes. No chunked-transmission support
// (the protocol's `m=1` continuation flag) — an image has to fit in one
// APC sequence within this buffer, a real, documented limitation. Fixed
// size (not allocator-backed) to keep Parser.init() trivial and every
// existing call site unchanged — the tradeoff is this buffer riding
// along with every Parser instance (one per pane) whether or not that
// pane ever receives an image.
const MAX_APC = 1 << 18; // 256 KiB

pub const CsiDispatch = struct {
    params: []const i64,
    intermediates: []const u8,
    final: u8,
    private: bool,
};

pub const EscDispatch = struct {
    intermediates: []const u8,
    final: u8,
};

pub const Action = union(enum) {
    print: u21,
    execute: u8,
    csi_dispatch: CsiDispatch,
    esc_dispatch: EscDispatch,
    osc_dispatch: []const u8,
    apc_dispatch: []const u8,
};

const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    osc_string,
    dcs_ignore,
    pm_ignore,
    apc_string,
};

pub const Parser = struct {
    state: State = .ground,

    params: [MAX_PARAMS]i64 = [_]i64{0} ** MAX_PARAMS,
    param_count: usize = 0,
    cur_param_set: bool = false,
    private_marker: bool = false,

    intermediates: [MAX_INTERMEDIATES]u8 = undefined,
    intermediate_count: usize = 0,

    osc_buf: [MAX_OSC]u8 = undefined,
    osc_len: usize = 0,

    apc_buf: [MAX_APC]u8 = undefined,
    apc_len: usize = 0,

    utf8_buf: [4]u8 = undefined,
    utf8_len: usize = 0,
    utf8_need: usize = 0,

    saw_esc_in_string: bool = false,

    pub fn init() Parser {
        return .{};
    }

    fn resetCsi(self: *Parser) void {
        self.param_count = 0;
        self.cur_param_set = false;
        self.private_marker = false;
        self.intermediate_count = 0;
    }

    fn pushParamDigit(self: *Parser, d: i64) void {
        if (self.param_count == 0) {
            self.param_count = 1;
            self.params[0] = 0;
        }
        const idx = self.param_count - 1;
        if (!self.cur_param_set) {
            self.params[idx] = 0;
            self.cur_param_set = true;
        }
        self.params[idx] = self.params[idx] * 10 + d;
    }

    fn nextParam(self: *Parser) void {
        if (self.param_count == 0) {
            self.param_count = 1;
            self.params[0] = 0;
        }
        if (self.param_count < MAX_PARAMS) {
            self.param_count += 1;
            self.params[self.param_count - 1] = 0;
        }
        self.cur_param_set = false;
    }

    fn pushIntermediate(self: *Parser, b: u8) void {
        if (self.intermediate_count < MAX_INTERMEDIATES) {
            self.intermediates[self.intermediate_count] = b;
            self.intermediate_count += 1;
        }
    }

    fn dispatchCsi(self: *Parser, final: u8) Action {
        return Action{ .csi_dispatch = .{
            .params = self.params[0..self.param_count],
            .intermediates = self.intermediates[0..self.intermediate_count],
            .final = final,
            .private = self.private_marker,
        } };
    }

    /// Feed one byte. Returns an Action if this byte completed one.
    /// Slices inside the returned Action point into this Parser's internal
    /// buffers and are valid only until the next call to `feed`.
    pub fn feed(self: *Parser, byte: u8) ?Action {
        if (self.state == .ground and self.utf8_need > 0) {
            if (byte >= 0x80 and byte <= 0xBF) {
                self.utf8_buf[self.utf8_len] = byte;
                self.utf8_len += 1;
                if (self.utf8_len == self.utf8_need) {
                    const cp = std.unicode.utf8Decode(self.utf8_buf[0..self.utf8_len]) catch 0xFFFD;
                    self.utf8_len = 0;
                    self.utf8_need = 0;
                    return Action{ .print = cp };
                }
                return null;
            }
            // malformed continuation: abandon and reprocess byte normally
            self.utf8_len = 0;
            self.utf8_need = 0;
        }

        return switch (self.state) {
            .ground => self.feedGround(byte),
            .escape => self.feedEscape(byte),
            .escape_intermediate => self.feedEscapeIntermediate(byte),
            .csi_entry => self.feedCsiEntry(byte),
            .csi_param => self.feedCsiParam(byte),
            .csi_intermediate => self.feedCsiIntermediate(byte),
            .csi_ignore => blk: {
                if (byte >= 0x40 and byte <= 0x7E) self.state = .ground;
                break :blk null;
            },
            .osc_string => self.feedOscString(byte),
            .apc_string => self.feedApcString(byte),
            .dcs_ignore, .pm_ignore => self.feedStringIgnore(byte),
        };
    }

    fn feedGround(self: *Parser, byte: u8) ?Action {
        if (byte == 0x1B) {
            self.state = .escape;
            return null;
        }
        if (byte < 0x20 or byte == 0x7F) {
            return Action{ .execute = byte };
        }
        if (byte < 0x80) {
            return Action{ .print = byte };
        }
        if (byte & 0xE0 == 0xC0) {
            self.utf8_need = 2;
        } else if (byte & 0xF0 == 0xE0) {
            self.utf8_need = 3;
        } else if (byte & 0xF8 == 0xF0) {
            self.utf8_need = 4;
        } else {
            return Action{ .print = 0xFFFD };
        }
        self.utf8_buf[0] = byte;
        self.utf8_len = 1;
        return null;
    }

    fn feedEscape(self: *Parser, byte: u8) ?Action {
        // An if/else chain (not a switch) on purpose: '[', ']', 'P', '^',
        // '_' all fall inside the 0x30...0x7E range too, and Zig's switch
        // rejects overlapping cases outright.
        if (byte == '[') {
            self.resetCsi();
            self.state = .csi_entry;
            return null;
        }
        if (byte == ']') {
            self.osc_len = 0;
            self.state = .osc_string;
            return null;
        }
        if (byte == 'P') {
            self.state = .dcs_ignore;
            return null;
        }
        if (byte == '^') {
            self.state = .pm_ignore;
            return null;
        }
        if (byte == '_') {
            self.apc_len = 0;
            self.state = .apc_string;
            return null;
        }
        if (byte >= 0x20 and byte <= 0x2F) {
            self.resetCsi();
            self.pushIntermediate(byte);
            self.state = .escape_intermediate;
            return null;
        }
        if (byte >= 0x30 and byte <= 0x7E) {
            self.state = .ground;
            return Action{ .esc_dispatch = .{ .intermediates = self.intermediates[0..0], .final = byte } };
        }
        self.state = .ground;
        return null;
    }

    fn feedEscapeIntermediate(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            0x20...0x2F => {
                self.pushIntermediate(byte);
                return null;
            },
            0x30...0x7E => {
                self.state = .ground;
                return Action{ .esc_dispatch = .{ .intermediates = self.intermediates[0..self.intermediate_count], .final = byte } };
            },
            else => {
                self.state = .ground;
                return null;
            },
        }
    }

    fn feedCsiEntry(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            '0'...'9' => {
                self.pushParamDigit(byte - '0');
                self.state = .csi_param;
                return null;
            },
            ';' => {
                self.nextParam();
                self.state = .csi_param;
                return null;
            },
            '<', '=', '>', '?' => {
                self.private_marker = true;
                self.state = .csi_param;
                return null;
            },
            0x20...0x2F => {
                self.pushIntermediate(byte);
                self.state = .csi_intermediate;
                return null;
            },
            0x40...0x7E => {
                self.state = .ground;
                return self.dispatchCsi(byte);
            },
            else => {
                self.state = .csi_ignore;
                return null;
            },
        }
    }

    fn feedCsiParam(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            '0'...'9' => {
                self.pushParamDigit(byte - '0');
                return null;
            },
            ';', ':' => {
                self.nextParam();
                return null;
            },
            0x20...0x2F => {
                self.pushIntermediate(byte);
                self.state = .csi_intermediate;
                return null;
            },
            0x40...0x7E => {
                self.state = .ground;
                return self.dispatchCsi(byte);
            },
            else => {
                self.state = .csi_ignore;
                return null;
            },
        }
    }

    fn feedCsiIntermediate(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            0x20...0x2F => {
                self.pushIntermediate(byte);
                return null;
            },
            0x40...0x7E => {
                self.state = .ground;
                return self.dispatchCsi(byte);
            },
            else => {
                self.state = .csi_ignore;
                return null;
            },
        }
    }

    fn feedOscString(self: *Parser, byte: u8) ?Action {
        if (byte == 0x07) {
            self.state = .ground;
            return Action{ .osc_dispatch = self.osc_buf[0..self.osc_len] };
        }
        if (byte == 0x1B) {
            self.saw_esc_in_string = true;
            return null;
        }
        if (self.saw_esc_in_string) {
            self.saw_esc_in_string = false;
            if (byte == '\\') {
                self.state = .ground;
                return Action{ .osc_dispatch = self.osc_buf[0..self.osc_len] };
            }
        }
        if (self.osc_len < MAX_OSC) {
            self.osc_buf[self.osc_len] = byte;
            self.osc_len += 1;
        }
        return null;
    }

    /// Same shape as feedOscString, terminated by BEL or ST — this is
    /// what carries kitty graphics-protocol payloads
    /// (`ESC _ G <control data> ; <base64 payload> ESC \`). If the
    /// payload overflows MAX_APC, it's truncated (bytes past the limit
    /// are dropped) rather than corrupting the parser state; kitty_
    /// graphics.zig will simply fail to decode a truncated payload.
    fn feedApcString(self: *Parser, byte: u8) ?Action {
        if (byte == 0x07) {
            self.state = .ground;
            return Action{ .apc_dispatch = self.apc_buf[0..self.apc_len] };
        }
        if (byte == 0x1B) {
            self.saw_esc_in_string = true;
            return null;
        }
        if (self.saw_esc_in_string) {
            self.saw_esc_in_string = false;
            if (byte == '\\') {
                self.state = .ground;
                return Action{ .apc_dispatch = self.apc_buf[0..self.apc_len] };
            }
        }
        if (self.apc_len < MAX_APC) {
            self.apc_buf[self.apc_len] = byte;
            self.apc_len += 1;
        }
        return null;
    }

    fn feedStringIgnore(self: *Parser, byte: u8) ?Action {
        if (byte == 0x1B) {
            self.saw_esc_in_string = true;
            return null;
        }
        if (self.saw_esc_in_string) {
            self.saw_esc_in_string = false;
            if (byte == '\\') self.state = .ground;
        }
        return null;
    }
};

test "prints plain ascii" {
    var p = Parser.init();
    const a = p.feed('A').?;
    try std.testing.expectEqual(Action{ .print = 'A' }, a);
}

test "parses SGR csi sequence" {
    var p = Parser.init();
    // ESC [ 1 ; 3 2 m
    for ("\x1b[1;32m") |b| {
        const a = p.feed(b);
        if (a) |act| {
            const csi = act.csi_dispatch;
            try std.testing.expectEqual(@as(u8, 'm'), csi.final);
            try std.testing.expectEqual(@as(usize, 2), csi.params.len);
            try std.testing.expectEqual(@as(i64, 1), csi.params[0]);
            try std.testing.expectEqual(@as(i64, 32), csi.params[1]);
        }
    }
}

test "decodes utf8 print" {
    var p = Parser.init();
    // 'é' = 0xC3 0xA9
    _ = p.feed(0xC3);
    const a = p.feed(0xA9).?;
    try std.testing.expectEqual(Action{ .print = 0xE9 }, a);
}

test "captures APC payload (kitty graphics protocol carrier)" {
    var p = Parser.init();
    const seq = "\x1b_Ga=T,f=32;AAAA\x1b\\"; // ESC _ G ... ST
    var last: ?Action = null;
    for (seq) |b| last = p.feed(b) orelse last;
    const apc = last.?.apc_dispatch;
    try std.testing.expectEqualStrings("Ga=T,f=32;AAAA", apc);
}
