/* noirterm/d2d_shim.h
 *
 * COBJMACROS gives us Zig-callable wrapper functions like
 * ID2D1RenderTarget_DrawText(this, ...) instead of raw vtable poking.
 * INITGUID + initguid.h makes IID_ID2D1Factory / IID_IDWriteFactory
 * compile in as real GUID data in this translation unit, since mingw-w64
 * doesn't ship a prebuilt import library defining these two symbols
 * (unlike MSVC's dxguid.lib/uuid.lib) — this sidesteps that gap entirely
 * rather than fighting the linker over it.
 */
#define COBJMACROS
#define INITGUID
#include <initguid.h>
#include <d2d1.h>
#include <dwrite.h>
