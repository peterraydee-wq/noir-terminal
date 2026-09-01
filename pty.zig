//! noirterm/pty.zig
//!
//! Platform dispatcher: picks the real backend for the target OS at
//! compile time. Everything above this file (main.zig, and later the
//! renderer/multiplexer) talks to `Pty` and never needs to know which
//! backend it got.

const builtin = @import("builtin");

pub const Pty = switch (builtin.os.tag) {
    .windows => @import("pty_windows.zig").Pty,
    else => @import("pty_linux.zig").Pty,
};
