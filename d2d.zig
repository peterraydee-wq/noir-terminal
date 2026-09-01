//! noirterm/d2d.zig
//!
//! Real GPU-accelerated rendering via Direct2D + DirectWrite. The COM
//! struct/vtable *layouts* (`c` below) come from @cImport-ing the actual
//! mingw-w64 d2d1.h/dwrite.h headers — not hand-transcribed. COM vtable
//! order is exactly the kind of thing that compiles fine when wrong and
//! only fails at runtime (wrong method called, or a crash) with nothing
//! for me to catch here without a real Windows box, so getting the
//! layout from the real header instead of memory removes the biggest
//! risk in this phase.
//!
//! NOTE on COBJMACROS: the header's COBJMACROS mode normally generates
//! safe `Interface_Method(this, ...)` wrapper functions, which is what
//! this file used at first — but they turned out to not compile in this
//! Zig version (translate-c emits `this.*.lpVtbl.*.Method(...)` without
//! the `.?` Zig requires to call an optional function pointer, so the
//! generated wrappers themselves are dead code that only errors when
//! actually instantiated). Worked around by calling through the vtables
//! directly instead, adding the missing `.?`. The exact field-access
//! paths used below (including which methods sit under a nested `.Base`
//! for inherited interfaces, and how deep) were confirmed directly from
//! the compiler's own error output while chasing this down — not
//! guessed — which is about as much confidence as this sandbox can
//! produce without a real Windows machine to run against.
//!
//! VERIFICATION STATUS: compiles, cross-compiles, and links against
//! d2d1.dll/dwrite.dll (confirmed via `zig build -Dtarget=x86_64-windows-gnu`).
//! Has NOT been run on real Windows — same caveat as the rest of this
//! project's Windows path. This is the highest-risk file in the repo;
//! please test it first and report back exactly what happens.

const std = @import("std");
pub const c = @cImport({
    @cInclude("d2d_shim.h");
});

const S_OK: i32 = 0;

pub const D2DError = error{
    CreateFactoryFailed,
    CreateDWriteFactoryFailed,
    CreateRenderTargetFailed,
    CreateBrushFailed,
    CreateTextFormatFailed,
};

pub const Context = struct {
    factory: *c.ID2D1Factory,
    dwrite_factory: *c.IDWriteFactory,
    render_target: *c.ID2D1HwndRenderTarget,
    brush: *c.ID2D1SolidColorBrush,
    text_format: *c.IDWriteTextFormat,

    /// `hwnd` is passed as `*anyopaque` rather than win32.zig's own HWND
    /// type on purpose — @cImport generates its own nominally distinct
    /// (if structurally identical) HWND type, so bridging at the API
    /// boundary here avoids needing @ptrCast at every call site.
    pub fn init(
        hwnd: *anyopaque,
        width: u32,
        height: u32,
        face_name_utf16: [:0]const u16,
        font_size: f32,
    ) D2DError!Context {
        var factory_ptr: ?*anyopaque = null;
        if (c.D2D1CreateFactory(c.D2D1_FACTORY_TYPE_SINGLE_THREADED, &c.IID_ID2D1Factory, null, &factory_ptr) != S_OK)
            return D2DError.CreateFactoryFailed;
        const factory: *c.ID2D1Factory = @ptrCast(@alignCast(factory_ptr.?));

        var dwrite_iunknown: ?*c.IUnknown = null;
        if (c.DWriteCreateFactory(c.DWRITE_FACTORY_TYPE_SHARED, &c.IID_IDWriteFactory, &dwrite_iunknown) != S_OK)
            return D2DError.CreateDWriteFactoryFailed;
        const dwrite_factory: *c.IDWriteFactory = @ptrCast(@alignCast(dwrite_iunknown.?));

        const rt_props = c.D2D1_RENDER_TARGET_PROPERTIES{
            .type = c.D2D1_RENDER_TARGET_TYPE_DEFAULT,
            .pixelFormat = .{ .format = c.DXGI_FORMAT_UNKNOWN, .alphaMode = c.D2D1_ALPHA_MODE_UNKNOWN },
            .dpiX = 0,
            .dpiY = 0,
            .usage = c.D2D1_RENDER_TARGET_USAGE_NONE,
            .minLevel = c.D2D1_FEATURE_LEVEL_DEFAULT,
        };
        var hwnd_rt_props = c.D2D1_HWND_RENDER_TARGET_PROPERTIES{
            .hwnd = undefined,
            .pixelSize = .{ .width = width, .height = height },
            .presentOptions = c.D2D1_PRESENT_OPTIONS_NONE,
        };
        // NOT `.hwnd = @ptrCast(@alignCast(hwnd))` — HWND is an opaque
        // Windows handle, not a real pointer with a guaranteed memory
        // alignment (Windows never promises handle values line up to
        // any boundary). @alignCast performs a genuine runtime check,
        // and it can — and, per an actual test run, does — fail for a
        // real HWND value. Writing the raw bits directly into the
        // field's storage sidesteps constructing an alignment-checked
        // pointer value at all, which is what we actually want here:
        // we never dereference this field ourselves, we're just
        // handing Direct2D the same opaque handle bit pattern Windows
        // gave us.
        @as(*usize, @ptrCast(&hwnd_rt_props.hwnd)).* = @intFromPtr(hwnd);
        var render_target: ?*c.ID2D1HwndRenderTarget = null;
        if (factory.*.lpVtbl.*.CreateHwndRenderTarget.?(factory, &rt_props, &hwnd_rt_props, &render_target) != S_OK)
            return D2DError.CreateRenderTargetFailed;
        const rt = render_target.?;

        var brush: ?*c.ID2D1SolidColorBrush = null;
        const white = c.D2D1_COLOR_F{ .r = 1, .g = 1, .b = 1, .a = 1 };
        const rt_as_render_target: [*c]c.ID2D1RenderTarget = @ptrCast(rt);
        if (rt.*.lpVtbl.*.Base.CreateSolidColorBrush.?(rt_as_render_target, &white, null, &brush) != S_OK)
            return D2DError.CreateBrushFailed;

        var text_format: ?*c.IDWriteTextFormat = null;
        const empty_locale = std.unicode.utf8ToUtf16LeStringLiteral("");
        if (dwrite_factory.*.lpVtbl.*.CreateTextFormat.?(
            dwrite_factory,
            face_name_utf16.ptr,
            null,
            c.DWRITE_FONT_WEIGHT_NORMAL,
            c.DWRITE_FONT_STYLE_NORMAL,
            c.DWRITE_FONT_STRETCH_NORMAL,
            font_size,
            empty_locale,
            &text_format,
        ) != S_OK) return D2DError.CreateTextFormatFailed;

        return Context{
            .factory = factory,
            .dwrite_factory = dwrite_factory,
            .render_target = rt,
            .brush = brush.?,
            .text_format = text_format.?,
        };
    }

    pub fn resize(self: *Context, width: u32, height: u32) void {
        const size = c.D2D1_SIZE_U{ .width = width, .height = height };
        _ = self.render_target.*.lpVtbl.*.Resize.?(self.render_target, &size);
    }

    pub fn setBrushColor(self: *Context, r: f32, g: f32, b: f32, a: f32) void {
        const color = c.D2D1_COLOR_F{ .r = r, .g = g, .b = b, .a = a };
        self.brush.*.lpVtbl.*.SetColor.?(self.brush, &color);
    }

    fn asRenderTarget(self: *Context) [*c]c.ID2D1RenderTarget {
        return @ptrCast(self.render_target);
    }

    pub fn beginDraw(self: *Context) void {
        self.render_target.*.lpVtbl.*.Base.BeginDraw.?(self.asRenderTarget());
    }

    /// Returns false if the device was lost (D2DERR_RECREATE_TARGET) —
    /// the caller should tear down and rebuild the whole Context if so.
    pub fn endDraw(self: *Context) bool {
        const hr = self.render_target.*.lpVtbl.*.Base.EndDraw.?(self.asRenderTarget(), null, null);
        return hr == S_OK;
    }

    pub fn clear(self: *Context, r: f32, g: f32, b: f32) void {
        const color = c.D2D1_COLOR_F{ .r = r, .g = g, .b = b, .a = 1 };
        self.render_target.*.lpVtbl.*.Base.Clear.?(self.asRenderTarget(), &color);
    }

    pub fn fillRect(self: *Context, left: f32, top: f32, right: f32, bottom: f32) void {
        const rect = c.D2D1_RECT_F{ .left = left, .top = top, .right = right, .bottom = bottom };
        const brush_as_brush: [*c]c.ID2D1Brush = @ptrCast(self.brush);
        self.render_target.*.lpVtbl.*.Base.FillRectangle.?(self.asRenderTarget(), &rect, brush_as_brush);
    }

    /// Draws `text` (already UTF-16) in the given rect with the current
    /// brush color. DirectWrite does real text shaping here — ligatures
    /// happen automatically if the selected font has them, no extra work
    /// needed on our end (this is the whole reason for this phase).
    ///
    /// The vtable field is `DrawTextA`, not `DrawText` — confirmed from
    /// this exact project's own @cImport output. The COM method really
    /// is just named "DrawText"; something in the transitively-included
    /// headers (COBJMACROS pulls in more than just d2d1.h/dwrite.h) is
    /// textually renaming it via the same `#define DrawText DrawTextA`
    /// macro pattern win32 uses for A/W function pairs — harmless here
    /// since we're calling the field translate-c actually produced, but
    /// worth knowing if this ever needs touching again.
    pub fn drawText(self: *Context, text: [:0]const u16, left: f32, top: f32, right: f32, bottom: f32) void {
        const rect = c.D2D1_RECT_F{ .left = left, .top = top, .right = right, .bottom = bottom };
        const brush_as_brush: [*c]c.ID2D1Brush = @ptrCast(self.brush);
        self.render_target.*.lpVtbl.*.Base.DrawTextA.?(
            self.asRenderTarget(),
            text.ptr,
            @intCast(text.len),
            self.text_format,
            &rect,
            brush_as_brush,
            c.D2D1_DRAW_TEXT_OPTIONS_NONE,
            c.DWRITE_MEASURING_MODE_NATURAL,
        );
    }

    /// Uploads raw RGBA pixels (straight, non-premultiplied alpha — the
    /// kitty graphics protocol doesn't premultiply, so telling D2D
    /// otherwise would blend colors wrong for any partially-transparent
    /// pixel) as a GPU bitmap. Returns null on failure; caller owns the
    /// returned bitmap and must releaseBitmap() it when done.
    pub fn createBitmap(self: *Context, width: u32, height: u32, rgba: []const u8) ?*c.ID2D1Bitmap {
        const size = c.D2D1_SIZE_U{ .width = width, .height = height };
        const props = c.D2D1_BITMAP_PROPERTIES{
            .pixelFormat = .{ .format = c.DXGI_FORMAT_R8G8B8A8_UNORM, .alphaMode = c.D2D1_ALPHA_MODE_STRAIGHT },
            .dpiX = 96,
            .dpiY = 96,
        };
        var bitmap: ?*c.ID2D1Bitmap = null;
        const pitch: u32 = width * 4;
        const hr = self.render_target.*.lpVtbl.*.Base.CreateBitmap.?(self.asRenderTarget(), size, rgba.ptr, pitch, &props, &bitmap);
        if (hr != S_OK) return null;
        return bitmap;
    }

    pub fn drawBitmap(self: *Context, bitmap: *c.ID2D1Bitmap, left: f32, top: f32, right: f32, bottom: f32) void {
        const rect = c.D2D1_RECT_F{ .left = left, .top = top, .right = right, .bottom = bottom };
        self.render_target.*.lpVtbl.*.Base.DrawBitmap.?(self.asRenderTarget(), bitmap, &rect, 1.0, c.D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, null);
    }

    pub fn releaseBitmap(bitmap: *c.ID2D1Bitmap) void {
        const as_unknown: [*c]c.IUnknown = @ptrCast(bitmap);
        _ = bitmap.*.lpVtbl.*.Base.Base.Base.Release.?(as_unknown);
    }
};
