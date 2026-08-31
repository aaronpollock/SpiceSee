/* The only header Swift sees. Wraps the vendored QUIC, LZ and GLZ decoders so that a corrupt
   stream returns an error rather than aborting: every entry point installs a jmp_buf that the
   vendored fatal paths unwind to. */
#ifndef SPICE_CODEC_H
#define SPICE_CODEC_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    SC_IMAGE_INVALID = 0, SC_IMAGE_GRAY, SC_IMAGE_RGB16, SC_IMAGE_RGB24, SC_IMAGE_RGB32, SC_IMAGE_RGBA,
    SC_IMAGE_PLT1_LE, SC_IMAGE_PLT1_BE, SC_IMAGE_PLT4_LE, SC_IMAGE_PLT4_BE, SC_IMAGE_PLT8, SC_IMAGE_XXXA
} sc_image_type;

/* ---- QUIC ---- */
typedef struct sc_quic sc_quic;
sc_quic *sc_quic_create(void);
void     sc_quic_destroy(sc_quic *);
/* 0 on success, <0 on corrupt input. Fills width/height/type. */
int      sc_quic_begin(sc_quic *, const uint8_t *data, size_t len, int *width, int *height, sc_image_type *type);
/* Writes BGRA (RGB32) or BGRA-with-alpha (RGBA) rows into out; stride may be negative for bottom-up. */
int      sc_quic_decode(sc_quic *, uint8_t *out, int stride);
/* Test helper: encodes 32bpp BGRA rows. Returns bytes written or <0. */
int      sc_quic_encode_rgb32(const uint8_t *pixels, int width, int height, int stride, uint8_t *out, size_t out_cap);

/* ---- LZ ---- */
typedef struct sc_lz sc_lz;
sc_lz   *sc_lz_create(void);
void     sc_lz_destroy(sc_lz *);
/* palette: up to 256 BGRx entries for PLT types, may be NULL otherwise. */
int      sc_lz_begin(sc_lz *, const uint8_t *data, size_t len, const uint32_t *palette, int palette_count,
                     int *width, int *height, sc_image_type *type, int *top_down);
/* out must hold width*height*4 bytes; written as RGB32 (or RGBA when type is RGBA). */
int      sc_lz_decode(sc_lz *, uint8_t *out);
int      sc_lz_encode_rgb32(const uint8_t *pixels, int width, int height, int stride, uint8_t *out, size_t out_cap);
/* Test helper: encodes a 32bpp buffer as an XXXA (alpha-only) plane, byte 3 of each pixel. */
int      sc_lz_encode_xxxa(const uint8_t *pixels, int width, int height, int stride, uint8_t *out, size_t out_cap);

/* ---- GLZ ---- */
typedef struct sc_glz_window sc_glz_window;
typedef struct sc_glz sc_glz;
sc_glz_window *sc_glz_window_create(void);
void           sc_glz_window_clear(sc_glz_window *);
void           sc_glz_window_destroy(sc_glz_window *);
sc_glz  *sc_glz_create(sc_glz_window *);
void     sc_glz_destroy(sc_glz *);
/* On success *out points at BGRA pixels owned by the window; copy before the next decode.
   top_down is 0 when the GLZ header marks the rows bottom-up, as Windows guests routinely send. */
int      sc_glz_decode(sc_glz *, const uint8_t *data, size_t len, const uint8_t **out, int *width, int *height, int *stride, int *top_down);

#ifdef __cplusplus
}
#endif
#endif
