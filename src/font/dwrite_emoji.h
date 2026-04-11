#ifndef DWRITE_EMOJI_H
#define DWRITE_EMOJI_H

#include <stdint.h>

/* Rendered emoji bitmap result. Caller must free data with dwrite_emoji_free(). */
typedef struct {
    uint8_t *data;      /* RGBA pixel data (pre-multiplied alpha) */
    uint32_t width;
    uint32_t height;
    int32_t bearing_x;
    int32_t bearing_y;
    uint32_t advance;
} DWriteEmojiBitmap;

/* Initialize DirectWrite emoji renderer. Call once at startup.
   Returns 0 on success, non-zero on failure. */
int dwrite_emoji_init(float font_size_pt, float dpi);

/* Render a multi-codepoint emoji sequence to an RGBA bitmap.
   codepoints: array of Unicode codepoints (e.g., [0x1F1FA, 0x1F1F8] for US flag)
   count: number of codepoints
   out: filled on success
   Returns 0 on success, non-zero on failure. */
int dwrite_emoji_render(const uint32_t *codepoints, uint32_t count, DWriteEmojiBitmap *out);

/* Update font size (e.g., after Ctrl+/- zoom). */
void dwrite_emoji_set_size(float font_size_pt, float dpi);

/* Free bitmap data returned by dwrite_emoji_render(). */
void dwrite_emoji_free(DWriteEmojiBitmap *bmp);

/* Shut down DirectWrite resources. Call once at exit. */
void dwrite_emoji_shutdown(void);

#endif
