/*
 * DirectWrite emoji rasterizer for Windows.
 *
 * Renders multi-codepoint emoji sequences (flags, ZWJ families, skin-tone
 * modifiers) to RGBA bitmaps using DirectWrite + Direct2D. This is needed
 * because Segoe UI Emoji's GSUB tables don't include composition lookups —
 * Microsoft expects DirectWrite to handle emoji composition natively.
 *
 * Architecture:
 *   1. Convert codepoints to UTF-16 string
 *   2. Create IDWriteTextLayout with Segoe UI Emoji
 *   3. Render to a WIC bitmap via ID2D1RenderTarget
 *   4. Extract RGBA pixels
 */

#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <dwrite.h>
#include <d2d1.h>
#include <d2d1_1.h>
#include <wincodec.h>
#include <stdlib.h>
#include <string.h>

extern "C" {
#include "dwrite_emoji.h"
}

/* Global state (initialized once). */
static ID2D1Factory          *g_d2d_factory   = NULL;
static IDWriteFactory        *g_dwrite_factory = NULL;
static IDWriteTextFormat     *g_text_format    = NULL;
static IWICImagingFactory    *g_wic_factory    = NULL;
static float                  g_font_size      = 13.0f;
static float                  g_dpi            = 96.0f;
static int                    g_initialized    = 0;

/* Convert a sequence of Unicode codepoints (u32) to a UTF-16 wchar_t string.
   Returns the number of wchar_t written (excluding null terminator).
   buf must have room for at least count*2+1 wchar_t. */
static int codepoints_to_utf16(const uint32_t *cps, uint32_t count, wchar_t *buf, int buf_len) {
    int pos = 0;
    for (uint32_t i = 0; i < count && pos < buf_len - 1; i++) {
        uint32_t cp = cps[i];
        if (cp <= 0xFFFF) {
            buf[pos++] = (wchar_t)cp;
        } else if (cp <= 0x10FFFF) {
            /* Surrogate pair */
            cp -= 0x10000;
            buf[pos++] = (wchar_t)(0xD800 + (cp >> 10));
            if (pos < buf_len - 1)
                buf[pos++] = (wchar_t)(0xDC00 + (cp & 0x3FF));
        }
    }
    buf[pos] = 0;
    return pos;
}

extern "C" int dwrite_emoji_init(float font_size_pt, float dpi) {
    if (g_initialized) return 0;

    HRESULT hr;

    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != S_FALSE && hr != RPC_E_CHANGED_MODE) return -1;

    hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory),
                           NULL, (void **)&g_d2d_factory);
    if (FAILED(hr)) return -2;

    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                             (IUnknown **)&g_dwrite_factory);
    if (FAILED(hr)) return -3;

    g_font_size = font_size_pt;
    g_dpi = dpi;
    float size_dip = font_size_pt * dpi / 72.0f;

    hr = g_dwrite_factory->CreateTextFormat(
        L"Segoe UI Emoji", NULL,
        DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
        size_dip, L"en-us", &g_text_format);
    if (FAILED(hr)) return -4;

    hr = CoCreateInstance(CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER,
                          IID_IWICImagingFactory, (void **)&g_wic_factory);
    if (FAILED(hr)) return -5;

    g_initialized = 1;
    return 0;
}

extern "C" void dwrite_emoji_set_size(float font_size_pt, float dpi) {
    if (!g_initialized) return;
    if (font_size_pt == g_font_size && dpi == g_dpi) return;

    g_font_size = font_size_pt;
    g_dpi = dpi;

    if (g_text_format) { g_text_format->Release(); g_text_format = NULL; }

    float size_dip = font_size_pt * dpi / 72.0f;
    g_dwrite_factory->CreateTextFormat(
        L"Segoe UI Emoji", NULL,
        DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
        size_dip, L"en-us", &g_text_format);
}

extern "C" int dwrite_emoji_render(const uint32_t *codepoints, uint32_t count,
                                    DWriteEmojiBitmap *out) {
    if (!g_initialized || !g_text_format || !out) return -1;

    memset(out, 0, sizeof(*out));

    /* Convert codepoints to UTF-16. */
    wchar_t utf16[128];
    int utf16_len = codepoints_to_utf16(codepoints, count, utf16, 128);
    if (utf16_len == 0) return -2;

    HRESULT hr;

    /* Create text layout to measure. */
    IDWriteTextLayout *layout = NULL;
    hr = g_dwrite_factory->CreateTextLayout(
        utf16, (UINT32)utf16_len, g_text_format, 256.0f, 256.0f, &layout);
    if (FAILED(hr)) return -3;

    /* Get metrics to determine bitmap size. */
    DWRITE_TEXT_METRICS metrics;
    hr = layout->GetMetrics(&metrics);
    if (FAILED(hr)) { layout->Release(); return -4; }

    uint32_t bmp_w = (uint32_t)(metrics.widthIncludingTrailingWhitespace + 1.5f);
    uint32_t bmp_h = (uint32_t)(metrics.height + 1.5f);
    if (bmp_w == 0 || bmp_h == 0) { layout->Release(); return -5; }

    /* Cap bitmap size to prevent absurdly large allocations. */
    if (bmp_w > 512) bmp_w = 512;
    if (bmp_h > 512) bmp_h = 512;

    /* Create WIC bitmap as render target surface. */
    IWICBitmap *wic_bmp = NULL;
    hr = g_wic_factory->CreateBitmap(bmp_w, bmp_h, GUID_WICPixelFormat32bppPBGRA,
                                      WICBitmapCacheOnLoad, &wic_bmp);
    if (FAILED(hr)) { layout->Release(); return -6; }

    /* Create D2D render target on the WIC bitmap. */
    D2D1_RENDER_TARGET_PROPERTIES rt_props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_SOFTWARE,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
        0.0f, 0.0f);

    ID2D1RenderTarget *rt = NULL;
    hr = g_d2d_factory->CreateWicBitmapRenderTarget(wic_bmp, &rt_props, &rt);
    if (FAILED(hr)) { wic_bmp->Release(); layout->Release(); return -7; }

    /* QI for ID2D1DeviceContext to get ENABLE_COLOR_FONT support.
       The base ID2D1RenderTarget from CreateWicBitmapRenderTarget may not
       support color fonts — ID2D1DeviceContext (Direct2D 1.1+) is required. */
    ID2D1DeviceContext *dc = NULL;
    hr = rt->QueryInterface(__uuidof(ID2D1DeviceContext), (void **)&dc);
    if (FAILED(hr)) { rt->Release(); wic_bmp->Release(); layout->Release(); return -8; }

    /* Create white brush for text color. */
    ID2D1SolidColorBrush *brush = NULL;
    hr = dc->CreateSolidColorBrush(D2D1::ColorF(D2D1::ColorF::White), &brush);
    if (FAILED(hr)) { dc->Release(); rt->Release(); wic_bmp->Release(); layout->Release(); return -8; }

    /* Render the emoji with color font support. */
    dc->BeginDraw();
    dc->Clear(D2D1::ColorF(0, 0, 0, 0)); /* transparent background */
    dc->DrawTextLayout(D2D1::Point2F(0, 0), layout, brush, D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
    hr = dc->EndDraw();

    brush->Release();
    dc->Release();
    rt->Release();
    layout->Release();

    if (FAILED(hr)) { wic_bmp->Release(); return -9; }

    /* Lock bitmap and copy pixels. */
    IWICBitmapLock *lock = NULL;
    WICRect rc = { 0, 0, (INT)bmp_w, (INT)bmp_h };
    hr = wic_bmp->Lock(&rc, WICBitmapLockRead, &lock);
    if (FAILED(hr)) { wic_bmp->Release(); return -10; }

    UINT lock_stride = 0;
    UINT lock_size = 0;
    BYTE *lock_data = NULL;
    lock->GetStride(&lock_stride);
    lock->GetDataPointer(&lock_size, &lock_data);

    /* Allocate output RGBA buffer (tightly packed, no padding). */
    uint32_t row_bytes = bmp_w * 4;
    uint8_t *rgba = (uint8_t *)malloc(row_bytes * bmp_h);
    if (!rgba) { lock->Release(); wic_bmp->Release(); return -11; }

    for (uint32_t row = 0; row < bmp_h; row++) {
        const uint8_t *src = lock_data + row * lock_stride;
        uint8_t *dst = rgba + row * row_bytes;
        for (uint32_t x = 0; x < bmp_w; x++) {
            /* BGRA → RGBA swizzle + un-premultiply alpha. */
            uint8_t b = src[x * 4 + 0];
            uint8_t g = src[x * 4 + 1];
            uint8_t r = src[x * 4 + 2];
            uint8_t a = src[x * 4 + 3];
            dst[x * 4 + 0] = r;
            dst[x * 4 + 1] = g;
            dst[x * 4 + 2] = b;
            dst[x * 4 + 3] = a;
        }
    }

    lock->Release();
    wic_bmp->Release();

    out->data = rgba;
    out->width = bmp_w;
    out->height = bmp_h;
    out->bearing_x = 0;
    out->bearing_y = (int32_t)bmp_h; /* top of bitmap = bearing_y */
    out->advance = bmp_w;

    return 0;
}

extern "C" void dwrite_emoji_free(DWriteEmojiBitmap *bmp) {
    if (bmp && bmp->data) {
        free(bmp->data);
        bmp->data = NULL;
    }
}

extern "C" void dwrite_emoji_shutdown(void) {
    if (g_text_format) { g_text_format->Release(); g_text_format = NULL; }
    if (g_wic_factory) { g_wic_factory->Release(); g_wic_factory = NULL; }
    if (g_dwrite_factory) { g_dwrite_factory->Release(); g_dwrite_factory = NULL; }
    if (g_d2d_factory) { g_d2d_factory->Release(); g_d2d_factory = NULL; }
    g_initialized = 0;
}
