/*
   Copyright (C) 2010 Red Hat, Inc.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2.1 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; if not, see <http://www.gnu.org/licenses/>.
*/
#pragma once

#include <glib.h>

#include "client_sw_canvas.h"

G_BEGIN_DECLS

typedef struct SpiceGlzDecoderWindow SpiceGlzDecoderWindow;

/* SPICESEE MODIFICATION: exposes the most recently decoded image to codec_bridge.c, which has no
   pixman surface to receive it through. Defined in decode-glz.c. See VENDORED.md. */
struct glz_image;
struct glz_image *glz_decoder_window_last(SpiceGlzDecoderWindow *w);
const uint8_t *sc_glz_image_data(const struct glz_image *img);
int sc_glz_image_width(const struct glz_image *img);
int sc_glz_image_height(const struct glz_image *img);
int sc_glz_image_stride(const struct glz_image *img);
int sc_glz_image_top_down(const struct glz_image *img);

SpiceGlzDecoderWindow *glz_decoder_window_new(void);
void glz_decoder_window_clear(SpiceGlzDecoderWindow *w);
void glz_decoder_window_destroy(SpiceGlzDecoderWindow *w);

SpiceGlzDecoder *glz_decoder_new(SpiceGlzDecoderWindow *w);
void glz_decoder_destroy(SpiceGlzDecoder *d);

SpiceZlibDecoder *zlib_decoder_new(void);
void zlib_decoder_destroy(SpiceZlibDecoder *d);

SpiceJpegDecoder *jpeg_decoder_new(void);
void jpeg_decoder_destroy(SpiceJpegDecoder *d);

G_END_DECLS
