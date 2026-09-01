//! noirterm/win32.zig
//!
//! Hand-declared user32.dll / gdi32.dll bindings. Zig's std.os.windows
//! only wraps the Win32 surface its own standard library needs (file I/O,
//! a bit of kernel32) — there's no windowing or GDI in there at all, so
//! everything below is declared directly against Microsoft's documented
//! (and extremely stable — this is 1990s-vintage, unchanged API surface)
//! Win32 ABI.
//!
//! Scope is deliberately minimal: just enough to open a window, pump a
//! message loop, and draw monospace text with per-cell fg/bg via GDI.
//! GDI is a legacy, non-shaping text API — it draws glyphs 1:1 with
//! characters and CANNOT do ligatures. This is the honest interim
//! renderer; real ligature support needs DirectWrite (a later phase),
//! which does contextual OpenType shaping GDI fundamentally can't.

const std = @import("std");
const windows = std.os.windows;

pub const HWND = windows.HWND;
pub const HDC = windows.HDC;
pub const HINSTANCE = windows.HINSTANCE;
pub const HICON = windows.HICON;
pub const HCURSOR = windows.HCURSOR;
pub const HBRUSH = windows.HBRUSH;
pub const HMENU = windows.HMENU;
pub const ATOM = windows.ATOM;
pub const WCHAR = windows.WCHAR;
pub const DWORD = windows.DWORD;
pub const BOOL = windows.BOOL;
pub const LONG = windows.LONG;
pub const LONG_PTR = windows.LONG_PTR;
pub const ULONG_PTR = windows.ULONG_PTR;
pub const LPCWSTR = windows.LPCWSTR;

pub const WPARAM = ULONG_PTR;
pub const LPARAM = LONG_PTR;
pub const LRESULT = LONG_PTR;
pub const COLORREF = u32;
pub const HGDIOBJ = *opaque {};
pub const HFONT = *opaque {};

pub const WNDPROC = *const fn (hwnd: HWND, msg: DWORD, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;

pub const POINT = extern struct { x: LONG, y: LONG };
pub const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };

pub const WNDCLASSEXW = extern struct {
    cbSize: DWORD = @sizeOf(WNDCLASSEXW),
    style: DWORD = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: HINSTANCE,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: LPCWSTR,
    hIconSm: ?HICON = null,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: DWORD,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD = 0,
};

pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

// --- window styles / messages / constants actually used ---
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

pub const WM_DESTROY: DWORD = 0x0002;
pub const WM_PAINT: DWORD = 0x000F;
pub const WM_CHAR: DWORD = 0x0102;
pub const WM_KEYDOWN: DWORD = 0x0100;
pub const WM_SIZE: DWORD = 0x0005;
pub const WM_APP: DWORD = 0x8000;
pub const WM_APP_PTY_DATA: DWORD = WM_APP + 1;

pub const VK_RETURN: WPARAM = 0x0D;
pub const VK_BACK: WPARAM = 0x08;
pub const VK_TAB: WPARAM = 0x09;
pub const VK_ESCAPE: WPARAM = 0x1B;
pub const VK_PRIOR: WPARAM = 0x21; // Page Up
pub const VK_NEXT: WPARAM = 0x22; // Page Down
pub const VK_LEFT: WPARAM = 0x25;
pub const VK_UP: WPARAM = 0x26;
pub const VK_RIGHT: WPARAM = 0x27;
pub const VK_DOWN: WPARAM = 0x28;
pub const VK_F2: WPARAM = 0x71;
pub const VK_F3: WPARAM = 0x72;
pub const VK_F4: WPARAM = 0x73;
pub const VK_F5: WPARAM = 0x74;

pub const SW_SHOWDEFAULT: i32 = 10;
pub const TRANSPARENT: i32 = 1;
pub const OPAQUE: i32 = 2;

pub const DEFAULT_CHARSET: u8 = 1;
pub const OUT_DEFAULT_PRECIS: u8 = 0;
pub const CLIP_DEFAULT_PRECIS: u8 = 0;
pub const CLEARTYPE_QUALITY: u8 = 5;
pub const FIXED_PITCH: u8 = 1;
pub const FF_MODERN: u8 = 0x30;
pub const FW_NORMAL: i32 = 400;
pub const FW_BOLD: i32 = 700;

// --- user32.dll ---
pub extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: ?LPCWSTR,
    lpWindowName: ?LPCWSTR,
    dwStyle: DWORD,
    x: i32,
    y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DefWindowProcW(hwnd: HWND, msg: DWORD, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetMessageW(lpMsg: *MSG, hwnd: ?HWND, wMsgFilterMin: DWORD, wMsgFilterMax: DWORD) callconv(.winapi) i32;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;
pub extern "user32" fn PostMessageW(hwnd: ?HWND, msg: DWORD, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn BeginPaint(hwnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) ?HDC;
pub extern "user32" fn EndPaint(hwnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(hwnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn InvalidateRect(hwnd: ?HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: usize) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn ShowWindow(hwnd: HWND, nCmdShow: i32) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetDC(hwnd: ?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(hwnd: ?HWND, hdc: HDC) callconv(.winapi) i32;
pub extern "user32" fn AdjustWindowRect(lpRect: *RECT, dwStyle: DWORD, bMenu: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn GetKeyState(nVirtKey: i32) callconv(.winapi) i16;

// --- kernel32.dll: file I/O, for loading a custom theme file ---
pub const HANDLE = windows.HANDLE;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
pub const GENERIC_READ: DWORD = 0x80000000;
pub const FILE_SHARE_READ: DWORD = 0x00000001;
pub const OPEN_EXISTING: DWORD = 3;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;

pub extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;
pub extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileSize(hFile: HANDLE, lpFileSizeHigh: ?*DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetEnvironmentVariableW(lpName: LPCWSTR, lpBuffer: [*]u16, nSize: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetCurrentDirectoryW(nBufferLength: DWORD, lpBuffer: [*]u16) callconv(.winapi) DWORD;
pub const CloseHandle = windows.CloseHandle;

// --- console mode, for raw-input TUI tools (file manager, music player) ---
pub const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
pub const ENABLE_ECHO_INPUT: DWORD = 0x0004;
pub const ENABLE_LINE_INPUT: DWORD = 0x0002;
pub const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
pub const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;

pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;
pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;

// --- gdi32.dll ---
pub extern "gdi32" fn TextOutW(hdc: HDC, x: i32, y: i32, lpString: [*]const WCHAR, c: i32) callconv(.winapi) BOOL;
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;
pub extern "gdi32" fn SetBkColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;
pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: i32) callconv(.winapi) i32;
pub extern "gdi32" fn CreateFontW(
    cHeight: i32,
    cWidth: i32,
    cEscapement: i32,
    cOrientation: i32,
    cWeight: i32,
    bItalic: DWORD,
    bUnderline: DWORD,
    bStrikeOut: DWORD,
    iCharSet: DWORD,
    iOutPrecision: DWORD,
    iClipPrecision: DWORD,
    iQuality: DWORD,
    iPitchAndFamily: DWORD,
    pszFaceName: LPCWSTR,
) callconv(.winapi) ?HFONT;
pub extern "gdi32" fn SelectObject(hdc: HDC, h: HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn DeleteObject(h: HGDIOBJ) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateSolidBrush(color: COLORREF) callconv(.winapi) ?HBRUSH;
pub extern "gdi32" fn FillRect(hdc: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(.winapi) i32;
pub extern "gdi32" fn GetTextExtentPoint32W(hdc: HDC, lpString: [*]const WCHAR, c: i32, lpSize: *POINT) callconv(.winapi) BOOL;

// --- kernel32.dll (not already in std.os.windows) ---
pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;

pub fn rgb(r: u8, g: u8, b: u8) COLORREF {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}
