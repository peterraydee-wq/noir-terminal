//! noirterm/window.zig
//!
//! Wires everything together for the Windows build: a real win32 window,
//! multiple tabs each holding a binary-split tree of panes
//! (layout.Layout), a background reader thread per pane, the existing
//! platform-agnostic parser/grid doing the actual interpretation, and a
//! real GPU-accelerated Direct2D/DirectWrite renderer. Pane borders and
//! the tab bar are drawn as plain ASCII characters ('|', '-', '+') on
//! purpose, matching this project's terminal/retro aesthetic rather than
//! Unicode box-drawing glyphs.
//!
//! VERIFICATION STATUS: compiles and cross-compiles cleanly. The pure
//! logic pieces (layout.zig's split/close/focus/rect math) are actually
//! unit-tested and passing — see layout.zig. Everything OS-facing here
//! (window creation, D2D, ConPTY, threading) has NOT been run on real
//! Windows, same caveat as the rest of this project. Please run it and
//! report back exactly what happens.
//!
//! Known gaps:
//!   - No reserved gutter between panes: the ASCII border is drawn
//!     directly on top of the split boundary rather than the layout
//!     reserving a dedicated 1-cell gap, so it slightly overlaps each
//!     pane's edge column. Simpler to implement; a visual polish item.
//!   - Closing the very last pane of the very last tab is a no-op
//!     rather than closing the app — there's nowhere for "zero tabs" to
//!     render, and that edge case needs a real decision (quit? spawn a
//!     fresh default tab?) rather than an accidental crash.
//!   - Keybindings (F2/F3/F4 split/split/close, Ctrl+Tab cycle focus,
//!     Ctrl+T new tab, Ctrl+PageUp/Down switch tabs) are placeholders —
//!     there's no config system yet (phase 5) to make these overridable.

const std = @import("std");
const win32 = @import("win32.zig");
const d2d = @import("d2d.zig");
const layout = @import("layout.zig");
const Pane = @import("pane.zig").Pane;
const renderer = @import("renderer_d2d.zig");
const color = @import("color.zig");
const theme = @import("theme.zig");

const INITIAL_COLS: usize = 80;
const INITIAL_ROWS: usize = 24;
const TAB_BAR_ROWS: f32 = 1;

const border_pipe = std.unicode.utf8ToUtf16LeStringLiteral("|");

const Tab = struct {
    panes: std.ArrayList(?*Pane) = .empty,
    layout: layout.Layout,
    name: []const u8,

    fn activePane(self: *Tab) ?*Pane {
        if (self.layout.focused >= self.panes.items.len) return null;
        return self.panes.items[self.layout.focused];
    }
};

const AppState = struct {
    allocator: std.mem.Allocator,
    hwnd: win32.HWND,
    d2d_ctx: d2d.Context,
    cell_w: f32,
    cell_h: f32,
    tabs: std.ArrayList(*Tab) = .empty,
    active_tab: usize = 0,
    next_tab_number: usize = 1,
    themes: theme.Registry,

    fn activeTab(self: *AppState) *Tab {
        return self.tabs.items[self.active_tab];
    }

    /// Pixel rect available for pane content — full client area minus
    /// the tab bar row at the top.
    fn paneAreaRect(self: *AppState, client_w: f32, client_h: f32) layout.Rect {
        const bar_h = self.cell_h * TAB_BAR_ROWS;
        return .{ .x = 0, .y = bar_h, .w = client_w, .h = @max(client_h - bar_h, self.cell_h) };
    }
};

/// Loads `%APPDATA%\noirterm\theme.ini` if it exists, parsed on top of
/// the everforest-dark defaults (so a file that only overrides a couple
/// of colors still produces a complete, usable theme). Returns null if
/// the env var isn't set, the file doesn't exist, or reading it fails
/// for any reason — a missing custom theme is a normal, silent case,
/// not an error worth surfacing.
fn loadCustomTheme(allocator: std.mem.Allocator) ?color.Theme {
    var appdata_buf: [512]u16 = undefined;
    const appdata_name = std.unicode.utf8ToUtf16LeStringLiteral("APPDATA");
    const appdata_len = win32.GetEnvironmentVariableW(appdata_name, &appdata_buf, appdata_buf.len);
    if (appdata_len == 0 or appdata_len >= appdata_buf.len) return null;

    var path_buf: [768]u16 = undefined;
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\\noirterm\\theme.ini");
    if (appdata_len + suffix.len >= path_buf.len) return null;
    @memcpy(path_buf[0..appdata_len], appdata_buf[0..appdata_len]);
    @memcpy(path_buf[appdata_len .. appdata_len + suffix.len], suffix);
    path_buf[appdata_len + suffix.len] = 0;
    const path: [:0]const u16 = path_buf[0 .. appdata_len + suffix.len :0];

    const file = win32.CreateFileW(path.ptr, win32.GENERIC_READ, win32.FILE_SHARE_READ, null, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, null);
    if (file == win32.INVALID_HANDLE_VALUE) return null;
    defer win32.CloseHandle(file);

    const size = win32.GetFileSize(file, null);
    if (size == 0 or size > 1 << 20) return null; // sanity bound, 1 MiB

    const buf = allocator.alloc(u8, size) catch return null;
    defer allocator.free(buf);
    var read: win32.DWORD = 0;
    if (win32.ReadFile(file, buf.ptr, size, &read, null) == win32.BOOL.FALSE) return null;

    return theme.parse(allocator, "custom", buf[0..read], color.everforest_dark) catch null;
}

// Single-window app: a module-level pointer is simpler and lower-risk
// than threading state through SetWindowLongPtrW/GetWindowLongPtrW.
var g_state: ?*AppState = null;

fn spawnPane(state: *AppState, tab: *Tab, cols: usize, rows: usize) !usize {
    const pane = try Pane.create(state.allocator, &.{"cmd.exe"}, cols, rows);
    try pane.startReaderThread(state.hwnd);
    // Reuse a tombstoned (closed) slot if one exists, else append.
    for (tab.panes.items, 0..) |slot, i| {
        if (slot == null) {
            tab.panes.items[i] = pane;
            return i;
        }
    }
    try tab.panes.append(state.allocator, pane);
    return tab.panes.items.len - 1;
}

fn newTab(state: *AppState) !void {
    const tab = try state.allocator.create(Tab);
    tab.* = .{ .layout = undefined, .name = try std.fmt.allocPrint(state.allocator, "{d}", .{state.next_tab_number}) };
    state.next_tab_number += 1;
    try state.tabs.append(state.allocator, tab);
    state.active_tab = state.tabs.items.len - 1;

    const idx = try spawnPane(state, tab, INITIAL_COLS, INITIAL_ROWS);
    tab.layout = try layout.Layout.initSingle(state.allocator, idx);
    try relayoutActiveTab(state);
}

fn splitActive(state: *AppState, direction: layout.Direction) !void {
    const tab = state.activeTab();
    const idx = try spawnPane(state, tab, INITIAL_COLS, INITIAL_ROWS);
    try tab.layout.splitFocused(state.allocator, direction, idx);
    try relayoutActiveTab(state);
}

fn closeActivePane(state: *AppState) !void {
    const tab = state.activeTab();
    const pane = tab.activePane() orelse return;
    const idx = tab.layout.focused;

    const emptied = try tab.layout.closePane(state.allocator, idx);
    pane.pty.close();
    state.allocator.destroy(pane);
    tab.panes.items[idx] = null;

    if (emptied) {
        if (state.tabs.items.len <= 1) return; // don't close the last tab/pane
        tab.layout.deinit(state.allocator);
        state.allocator.destroy(tab);
        _ = state.tabs.orderedRemove(state.active_tab);
        if (state.active_tab >= state.tabs.items.len) state.active_tab = state.tabs.items.len - 1;
    }
    try relayoutActiveTab(state);
}

fn switchTab(state: *AppState, delta: isize) !void {
    if (state.tabs.items.len <= 1) return;
    const n: isize = @intCast(state.tabs.items.len);
    const cur: isize = @intCast(state.active_tab);
    state.active_tab = @intCast(@mod(cur + delta, n));
    try relayoutActiveTab(state);
}

const RelayoutCtx = struct {
    state: *AppState,
    tab: *Tab,

    pub fn visit(self: *@This(), idx: usize, rect: layout.Rect) void {
        const pane = self.tab.panes.items[idx] orelse return;
        const cols: usize = @max(1, @as(usize, @intFromFloat(rect.w / self.state.cell_w)));
        const rows: usize = @max(1, @as(usize, @intFromFloat(rect.h / self.state.cell_h)));
        pane.resize(cols, rows) catch {};
    }
};

fn relayoutActiveTab(state: *AppState) !void {
    var rc = win32.RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = win32.GetClientRect(state.hwnd, &rc);
    const client_w: f32 = @floatFromInt(rc.right - rc.left);
    const client_h: f32 = @floatFromInt(rc.bottom - rc.top);
    const pane_area = state.paneAreaRect(client_w, client_h);

    const tab = state.activeTab();
    var ctx = RelayoutCtx{ .state = state, .tab = tab };
    tab.layout.walk(pane_area, &ctx);
    _ = win32.InvalidateRect(state.hwnd, null, win32.BOOL.FALSE);
}

const BorderCtx = struct {
    d2d_ctx: *d2d.Context,
    cell_w: f32,
    cell_h: f32,

    pub fn visitSplit(self: *@This(), direction: layout.Direction, rect: layout.Rect) void {
        const gray = color.active.border;
        self.d2d_ctx.setBrushColor(renderer.toUnit(gray.r), renderer.toUnit(gray.g), renderer.toUnit(gray.b), 1.0);
        switch (direction) {
            .vertical => {
                // horizontal divider: one row of '-' across the width
                var buf: [512]u16 = undefined;
                const n: usize = @min(@as(usize, @intFromFloat(rect.w / self.cell_w)), buf.len - 1);
                for (buf[0..n]) |*c| c.* = '-';
                buf[n] = 0;
                self.d2d_ctx.drawText(buf[0..n :0], rect.x, rect.y, rect.x + rect.w, rect.y + self.cell_h);
            },
            .horizontal => {
                // vertical divider: '|' repeated down each row (DrawText
                // lays out horizontally, so a vertical line is one draw
                // call per row rather than a single call).
                const rows: usize = @intFromFloat(rect.h / self.cell_h);
                var i: usize = 0;
                while (i < rows) : (i += 1) {
                    const y = rect.y + @as(f32, @floatFromInt(i)) * self.cell_h;
                    self.d2d_ctx.drawText(border_pipe, rect.x, y, rect.x + self.cell_w, y + self.cell_h);
                }
            },
        }
    }
};

fn paintTabBar(state: *AppState, client_w: f32) void {
    var x: f32 = 0;
    for (state.tabs.items, 0..) |tab, i| {
        var label_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, " {d}:{s} ", .{ i + 1, tab.name }) catch " ? ";
        var wide_buf: [64]u16 = undefined;
        const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, label) catch 0;
        if (wide_len == 0) continue;
        wide_buf[wide_len] = 0;

        const width = @as(f32, @floatFromInt(label.len)) * state.cell_w;
        const active = i == state.active_tab;
        const fg = color.active.default_fg;
        const bg = color.active.border;
        const use_fg = if (active) bg else fg;
        const use_bg = if (active) fg else bg;

        state.d2d_ctx.setBrushColor(renderer.toUnit(use_bg.r), renderer.toUnit(use_bg.g), renderer.toUnit(use_bg.b), 1.0);
        state.d2d_ctx.fillRect(x, 0, x + width, state.cell_h);
        state.d2d_ctx.setBrushColor(renderer.toUnit(use_fg.r), renderer.toUnit(use_fg.g), renderer.toUnit(use_fg.b), 1.0);
        state.d2d_ctx.drawText(wide_buf[0..wide_len :0], x, 0, x + width, state.cell_h);
        x += width;
    }
    _ = client_w;
}

fn paintAll(state: *AppState) void {
    state.d2d_ctx.beginDraw();
    const bg0 = color.active.default_bg;
    state.d2d_ctx.clear(renderer.toUnit(bg0.r), renderer.toUnit(bg0.g), renderer.toUnit(bg0.b));

    var rc = win32.RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = win32.GetClientRect(state.hwnd, &rc);
    const client_w: f32 = @floatFromInt(rc.right - rc.left);
    const client_h: f32 = @floatFromInt(rc.bottom - rc.top);
    const pane_area = state.paneAreaRect(client_w, client_h);

    paintTabBar(state, client_w);

    const tab = state.activeTab();
    const PaintCtx = struct {
        state2: *AppState,
        tab2: *Tab,
        pub fn visit(self: @This(), idx: usize, rect: layout.Rect) void {
            const pane = self.tab2.panes.items[idx] orelse return;
            renderer.paintGrid(&self.state2.d2d_ctx, &pane.grid, rect.x, rect.y, self.state2.cell_w, self.state2.cell_h);
        }
    };
    tab.layout.walk(pane_area, PaintCtx{ .state2 = state, .tab2 = tab });

    var border_ctx = BorderCtx{ .d2d_ctx = &state.d2d_ctx, .cell_w = state.cell_w, .cell_h = state.cell_h };
    tab.layout.walkSplits(pane_area, &border_ctx);

    _ = state.d2d_ctx.endDraw();
}

fn wndProc(hwnd: win32.HWND, msg: win32.DWORD, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    const state = g_state orelse return win32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_PAINT => {
            var ps: win32.PAINTSTRUCT = undefined;
            _ = win32.BeginPaint(hwnd, &ps) orelse return 0;
            paintAll(state);
            _ = win32.EndPaint(hwnd, &ps);
            return 0;
        },
        win32.WM_SIZE => {
            const width: u32 = @intCast(lparam & 0xFFFF);
            const height: u32 = @intCast((lparam >> 16) & 0xFFFF);
            state.d2d_ctx.resize(width, height);
            relayoutActiveTab(state) catch {};
            return 0;
        },
        win32.WM_APP_PTY_DATA => {
            const pane: *Pane = @ptrFromInt(@as(usize, @bitCast(lparam)));
            pane.drain();
            _ = win32.InvalidateRect(hwnd, null, win32.BOOL.FALSE);
            return 0;
        },
        win32.WM_CHAR => {
            // Fires post-keyboard-layout-translation: gives us real
            // Unicode text (and, per standard Windows keyboard tables,
            // the right control-character codes for Ctrl+letter combos)
            // without us reimplementing layout handling ourselves.
            const cp: u21 = @intCast(wparam & 0xFFFF);
            var utf8: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &utf8) catch return 0;
            if (state.activeTab().activePane()) |pane| pane.write(utf8[0..len]);
            return 0;
        },
        win32.WM_KEYDOWN => {
            const ctrl_down = win32.GetKeyState(0x11) < 0; // VK_CONTROL
            switch (wparam) {
                win32.VK_UP => if (state.activeTab().activePane()) |p| p.write("\x1b[A"),
                win32.VK_DOWN => if (state.activeTab().activePane()) |p| p.write("\x1b[B"),
                win32.VK_RIGHT => if (state.activeTab().activePane()) |p| p.write("\x1b[C"),
                win32.VK_LEFT => if (state.activeTab().activePane()) |p| p.write("\x1b[D"),
                win32.VK_F2 => splitActive(state, .horizontal) catch {},
                win32.VK_F3 => splitActive(state, .vertical) catch {},
                win32.VK_F4 => closeActivePane(state) catch {},
                win32.VK_F5 => {
                    state.themes.cycleNext();
                    _ = win32.InvalidateRect(hwnd, null, win32.BOOL.FALSE);
                },
                win32.VK_TAB => if (ctrl_down) {
                    state.activeTab().layout.cycleFocus(state.allocator) catch {};
                    _ = win32.InvalidateRect(hwnd, null, win32.BOOL.FALSE);
                },
                'T' => if (ctrl_down) newTab(state) catch {},
                win32.VK_PRIOR => if (ctrl_down) switchTab(state, -1) catch {}, // Ctrl+PageUp
                win32.VK_NEXT => if (ctrl_down) switchTab(state, 1) catch {}, // Ctrl+PageDown
                else => {},
            }
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

pub fn run(allocator: std.mem.Allocator) !void {
    const h_instance = win32.GetModuleHandleW(null) orelse return error.NoModuleHandle;
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("NoirTerminalWindowClass");
    const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Noir Terminal");
    const face_name = std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
    const font_size: f32 = 18.0;

    var wc = win32.WNDCLASSEXW{
        .lpfnWndProc = wndProc,
        .hInstance = h_instance,
        .lpszClassName = class_name,
        .hCursor = win32.LoadCursorW(null, 32512), // IDC_ARROW
    };
    if (win32.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;

    // Approximate monospace cell size via GDI, just for initial window
    // sizing — see the "font_size" note in d2d.zig's Context.init caller
    // below for why this isn't pixel-exact with DirectWrite's own layout.
    const gdi_font = win32.CreateFontW(
        -@as(i32, @intFromFloat(font_size)),
        0,
        0,
        0,
        win32.FW_NORMAL,
        0,
        0,
        0,
        win32.DEFAULT_CHARSET,
        win32.OUT_DEFAULT_PRECIS,
        win32.CLIP_DEFAULT_PRECIS,
        win32.CLEARTYPE_QUALITY,
        win32.FIXED_PITCH | win32.FF_MODERN,
        face_name,
    ) orelse return error.CreateFontFailed;
    const screen_dc = win32.GetDC(null) orelse return error.GetDCFailed;
    _ = win32.SelectObject(screen_dc, @ptrCast(gdi_font));
    var extent: win32.POINT = undefined;
    const sample = std.unicode.utf8ToUtf16LeStringLiteral("M");
    _ = win32.GetTextExtentPoint32W(screen_dc, sample, 1, &extent);
    _ = win32.ReleaseDC(null, screen_dc);
    _ = win32.DeleteObject(@ptrCast(gdi_font));
    const cell_w_px = extent.x;
    const cell_h_px = extent.y;

    var rect = win32.RECT{
        .left = 0,
        .top = 0,
        .right = @intCast(cell_w_px * @as(i32, @intCast(INITIAL_COLS))),
        .bottom = @intCast(cell_h_px * (@as(i32, @intCast(INITIAL_ROWS)) + 1)), // +1 row for the tab bar
    };
    _ = win32.AdjustWindowRect(&rect, win32.WS_OVERLAPPEDWINDOW, win32.BOOL.FALSE);

    const hwnd = win32.CreateWindowExW(
        0,
        class_name,
        window_title,
        win32.WS_OVERLAPPEDWINDOW | win32.WS_VISIBLE,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        rect.right - rect.left,
        rect.bottom - rect.top,
        null,
        null,
        h_instance,
        null,
    ) orelse return error.CreateWindowFailed;

    const client_w: u32 = @intCast(cell_w_px * @as(i32, @intCast(INITIAL_COLS)));
    const client_h: u32 = @intCast(cell_h_px * (@as(i32, @intCast(INITIAL_ROWS)) + 1));
    const d2d_ctx = try d2d.Context.init(@ptrCast(hwnd), client_w, client_h, face_name, font_size);

    var themes = try theme.Registry.initBuiltins(allocator);
    if (loadCustomTheme(allocator)) |custom| {
        try themes.add(allocator, custom);
        themes.active_index = themes.themes.items.len - 1; // start on the user's own theme, if they have one
    }
    themes.applyActive();

    const state = try allocator.create(AppState);
    state.* = .{
        .allocator = allocator,
        .hwnd = hwnd,
        .d2d_ctx = d2d_ctx,
        .cell_w = @floatFromInt(cell_w_px),
        .cell_h = @floatFromInt(cell_h_px),
        .themes = themes,
    };
    g_state = state;

    try newTab(state);

    _ = win32.ShowWindow(hwnd, win32.SW_SHOWDEFAULT);
    _ = win32.UpdateWindow(hwnd);

    var msg: win32.MSG = undefined;
    while (win32.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}
