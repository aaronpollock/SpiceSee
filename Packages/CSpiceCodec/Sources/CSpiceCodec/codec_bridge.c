/* Wraps the vendored QUIC, LZ and GLZ decoders behind spice_codec.h.
   Not upstream code.

   The vendored codecs report corruption by calling usr->error(), which upstream expects never to
   return. Every entry point here installs a jmp_buf first, so those paths unwind into an error
   return instead of aborting: a hostile server must not be able to kill the process. */
#include "spice_codec.h"
#include "spice_common.h"
#include "common/quic.h"
#include "common/lz.h"
#include "decode.h"
#include <stdarg.h>

_Thread_local jmp_buf *sc_fatal_env;

void sc_fatal(const char *fmt, ...)
{
    (void)fmt;
    if (sc_fatal_env) {
        longjmp(*sc_fatal_env, 1);
    }
    abort();
}

#define SC_GUARD(env) jmp_buf env; jmp_buf *sc_prev = sc_fatal_env; sc_fatal_env = &env; \
    if (setjmp(env)) { sc_fatal_env = sc_prev; return -1; }
#define SC_UNGUARD() sc_fatal_env = sc_prev

/* ---- QUIC ---- */

struct sc_quic { QuicUsrContext usr; QuicContext *ctx; QuicImageType type; int width, height; };

SPICE_GNUC_NORETURN static void q_error(QuicUsrContext *u, const char *fmt, ...) { (void)u; sc_fatal(fmt); abort(); }
static void q_warn(QuicUsrContext *u, const char *fmt, ...) { (void)u; (void)fmt; }
static void q_info(QuicUsrContext *u, const char *fmt, ...) { (void)u; (void)fmt; }
static void *q_malloc(QuicUsrContext *u, int n) { (void)u; return malloc((size_t)n); }
static void q_free(QuicUsrContext *u, void *p) { (void)u; free(p); }
static int q_more_space(QuicUsrContext *u, uint32_t **io, int rows_completed) { (void)u; (void)io; (void)rows_completed; return 0; }
static int q_more_lines(QuicUsrContext *u, uint8_t **lines) { (void)u; (void)lines; return 0; }

sc_quic *sc_quic_create(void)
{
    sc_quic *q = calloc(1, sizeof *q);
    if (!q) return NULL;
    q->usr.error = q_error; q->usr.warn = q_warn; q->usr.info = q_info;
    q->usr.malloc = q_malloc; q->usr.free = q_free;
    q->usr.more_space = q_more_space; q->usr.more_lines = q_more_lines;
    q->ctx = quic_create(&q->usr);
    if (!q->ctx) { free(q); return NULL; }
    return q;
}

void sc_quic_destroy(sc_quic *q) { if (q) { quic_destroy(q->ctx); free(q); } }

static sc_image_type from_quic(QuicImageType t)
{
    switch (t) {
    case QUIC_IMAGE_TYPE_GRAY:  return SC_IMAGE_GRAY;
    case QUIC_IMAGE_TYPE_RGB16: return SC_IMAGE_RGB16;
    case QUIC_IMAGE_TYPE_RGB24: return SC_IMAGE_RGB24;
    case QUIC_IMAGE_TYPE_RGB32: return SC_IMAGE_RGB32;
    case QUIC_IMAGE_TYPE_RGBA:  return SC_IMAGE_RGBA;
    default:                    return SC_IMAGE_INVALID;
    }
}

int sc_quic_begin(sc_quic *q, const uint8_t *data, size_t len, int *w, int *h, sc_image_type *type)
{
    if (!q || !data || len < 4) return -1;
    SC_GUARD(env);
    int r = quic_decode_begin(q->ctx, (uint32_t *)(void *)(uintptr_t)data, (unsigned)(len / 4),
                              &q->type, &q->width, &q->height);
    SC_UNGUARD();
    if (r != QUIC_OK) return -1;
    *w = q->width; *h = q->height; *type = from_quic(q->type);
    return *type == SC_IMAGE_INVALID ? -1 : 0;
}

int sc_quic_decode(sc_quic *q, uint8_t *out, int stride)
{
    if (!q || !out) return -1;
    SC_GUARD(env);
    QuicImageType to = q->type == QUIC_IMAGE_TYPE_RGBA ? QUIC_IMAGE_TYPE_RGBA : QUIC_IMAGE_TYPE_RGB32;
    int r = quic_decode(q->ctx, to, out, stride);
    SC_UNGUARD();
    return r == QUIC_OK ? 0 : -1;
}

int sc_quic_encode_rgb32(const uint8_t *px, int w, int h, int stride, uint8_t *out, size_t cap)
{
    if (!px || !out || w <= 0 || h <= 0) return -1;
    sc_quic *q = sc_quic_create();
    if (!q) return -1;
    int words;
    {
        SC_GUARD(env);
        words = quic_encode(q->ctx, QUIC_IMAGE_TYPE_RGB32, w, h,
                            (uint8_t *)(uintptr_t)px, (unsigned)h, stride,
                            (uint32_t *)(void *)out, (unsigned)(cap / 4));
        SC_UNGUARD();
    }
    sc_quic_destroy(q);
    return words > 0 ? words * 4 : -1;
}

/* ---- LZ ---- */

struct sc_lz {
    LzUsrContext usr;
    LzContext *ctx;
    LzImageType type;
    int width, height, n_pixels, top_down;
};

SPICE_GNUC_NORETURN static void l_error(LzUsrContext *u, const char *fmt, ...) { (void)u; sc_fatal(fmt); abort(); }
static void l_warn(LzUsrContext *u, const char *fmt, ...) { (void)u; (void)fmt; }
static void l_info(LzUsrContext *u, const char *fmt, ...) { (void)u; (void)fmt; }
static void *l_malloc(LzUsrContext *u, int n) { (void)u; return malloc((size_t)n); }
static void l_free(LzUsrContext *u, void *p) { (void)u; free(p); }
static int l_more_space(LzUsrContext *u, uint8_t **io) { (void)u; (void)io; return 0; }
static int l_more_lines(LzUsrContext *u, uint8_t **lines) { (void)u; (void)lines; return 0; }

sc_lz *sc_lz_create(void)
{
    sc_lz *z = calloc(1, sizeof *z);
    if (!z) return NULL;
    z->usr.error = l_error; z->usr.warn = l_warn; z->usr.info = l_info;
    z->usr.malloc = l_malloc; z->usr.free = l_free;
    z->usr.more_space = l_more_space; z->usr.more_lines = l_more_lines;
    z->ctx = lz_create(&z->usr);
    if (!z->ctx) { free(z); return NULL; }
    return z;
}

void sc_lz_destroy(sc_lz *z) { if (z) { lz_destroy(z->ctx); free(z); } }

static sc_image_type from_lz(LzImageType t)
{
    switch (t) {
    case LZ_IMAGE_TYPE_PLT1_LE: return SC_IMAGE_PLT1_LE;
    case LZ_IMAGE_TYPE_PLT1_BE: return SC_IMAGE_PLT1_BE;
    case LZ_IMAGE_TYPE_PLT4_LE: return SC_IMAGE_PLT4_LE;
    case LZ_IMAGE_TYPE_PLT4_BE: return SC_IMAGE_PLT4_BE;
    case LZ_IMAGE_TYPE_PLT8:    return SC_IMAGE_PLT8;
    case LZ_IMAGE_TYPE_RGB16:   return SC_IMAGE_RGB16;
    case LZ_IMAGE_TYPE_RGB24:   return SC_IMAGE_RGB24;
    case LZ_IMAGE_TYPE_RGB32:   return SC_IMAGE_RGB32;
    case LZ_IMAGE_TYPE_RGBA:    return SC_IMAGE_RGBA;
    case LZ_IMAGE_TYPE_XXXA:    return SC_IMAGE_XXXA;
    default:                    return SC_IMAGE_INVALID;
    }
}

int sc_lz_begin(sc_lz *z, const uint8_t *data, size_t len, const uint32_t *palette, int palette_count,
                int *w, int *h, sc_image_type *type, int *top_down)
{
    if (!z || !data || len < 4) return -1;

    SpicePalette *plt = NULL;
    if (palette && palette_count > 0) {
        if (palette_count > 256) return -1;
        plt = calloc(1, sizeof(SpicePalette) + (size_t)palette_count * sizeof(uint32_t));
        if (!plt) return -1;
        plt->num_ents = (uint16_t)palette_count;
        memcpy(plt->ents, palette, (size_t)palette_count * sizeof(uint32_t));
    }

    jmp_buf env; jmp_buf *sc_prev = sc_fatal_env; sc_fatal_env = &env;
    if (setjmp(env)) { sc_fatal_env = sc_prev; free(plt); return -1; }
    lz_decode_begin(z->ctx, (uint8_t *)(uintptr_t)data, (unsigned)len,
                    &z->type, &z->width, &z->height, &z->n_pixels, &z->top_down, plt);
    sc_fatal_env = sc_prev;
    free(plt);

    *w = z->width; *h = z->height; *top_down = z->top_down;
    *type = from_lz(z->type);
    return *type == SC_IMAGE_INVALID ? -1 : 0;
}

int sc_lz_decode(sc_lz *z, uint8_t *out)
{
    if (!z || !out) return -1;
    SC_GUARD(env);
    LzImageType to = z->type == LZ_IMAGE_TYPE_RGBA ? LZ_IMAGE_TYPE_RGBA : LZ_IMAGE_TYPE_RGB32;
    lz_decode(z->ctx, to, out);
    SC_UNGUARD();
    return 0;
}

int sc_lz_encode_rgb32(const uint8_t *px, int w, int h, int stride, uint8_t *out, size_t cap)
{
    if (!px || !out || w <= 0 || h <= 0) return -1;
    sc_lz *z = sc_lz_create();
    if (!z) return -1;
    int n;
    {
        SC_GUARD(env);
        n = lz_encode(z->ctx, LZ_IMAGE_TYPE_RGB32, w, h, 1 /* top_down */,
                      (uint8_t *)(uintptr_t)px, (unsigned)h, stride, out, (unsigned)cap);
        SC_UNGUARD();
    }
    sc_lz_destroy(z);
    return n > 0 ? n : -1;
}

/* ---- GLZ ---- */

struct sc_glz_window { SpiceGlzDecoderWindow *w; };
struct sc_glz { SpiceGlzDecoder *d; sc_glz_window *win; };

sc_glz_window *sc_glz_window_create(void)
{
    sc_glz_window *w = calloc(1, sizeof *w);
    if (!w) return NULL;
    w->w = glz_decoder_window_new();
    return w;
}

void sc_glz_window_clear(sc_glz_window *w) { if (w) glz_decoder_window_clear(w->w); }
void sc_glz_window_destroy(sc_glz_window *w) { if (w) { glz_decoder_window_destroy(w->w); free(w); } }

sc_glz *sc_glz_create(sc_glz_window *w)
{
    if (!w) return NULL;
    sc_glz *g = calloc(1, sizeof *g);
    if (!g) return NULL;
    g->win = w;
    g->d = glz_decoder_new(w->w);
    return g;
}

void sc_glz_destroy(sc_glz *g) { if (g) { glz_decoder_destroy(g->d); free(g); } }

int sc_glz_decode(sc_glz *g, const uint8_t *data, size_t len, const uint8_t **out,
                  int *w, int *h, int *stride, int *top_down)
{
    if (!g || !data || len < 4) return -1;
    (void)len;   /* the GLZ stream is self-delimiting; the window bounds every back-reference */
    SC_GUARD(env);
    g->d->ops->decode(g->d, (uint8_t *)(uintptr_t)data, NULL, NULL);
    SC_UNGUARD();

    struct glz_image *img = glz_decoder_window_last(g->win->w);
    if (!img) return -1;
    *out = sc_glz_image_data(img);
    *w = sc_glz_image_width(img);
    *h = sc_glz_image_height(img);
    *stride = sc_glz_image_stride(img);
    *top_down = sc_glz_image_top_down(img);
    return 0;
}
