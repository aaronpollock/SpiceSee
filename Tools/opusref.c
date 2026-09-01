// Encodes the M6 audio fixture with libopus (a real, independent encoder) so Apple's decoder is
// tested against something it did not produce. Framing: [u32 LE length][packet bytes] × 100.
//   cc -I$(brew --prefix opus)/include -L$(brew --prefix opus)/lib -lopus -lm -o /tmp/opusref Tools/opusref.c
//   /tmp/opusref Tests/SpiceMediaTests/Fixtures/tone-48k-stereo.opus.bin
#include <opus/opus.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define FRAMES 480          /* SPICE's SND_CODEC_OPUS_FRAME_SIZE: 10 ms at 48 kHz */
#define PACKETS 100

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: opusref <out.bin>\n"); return 2; }
    int err = 0;
    OpusEncoder *enc = opus_encoder_create(48000, 2, OPUS_APPLICATION_AUDIO, &err);
    if (err != OPUS_OK) { fprintf(stderr, "encoder: %s\n", opus_strerror(err)); return 1; }
    opus_encoder_ctl(enc, OPUS_SET_BITRATE(96000));
    FILE *out = fopen(argv[1], "wb");
    if (!out) { perror(argv[1]); return 1; }
    int16_t pcm[FRAMES * 2];
    unsigned char buf[4000];
    double phase = 0;
    for (int p = 0; p < PACKETS; p++) {
        for (int i = 0; i < FRAMES; i++) {
            int16_t s = (int16_t)(0.5 * 32767 * sin(phase));
            pcm[i * 2] = s; pcm[i * 2 + 1] = s;
            phase += 2 * M_PI * 440.0 / 48000.0;
        }
        int n = opus_encode(enc, pcm, FRAMES, buf, sizeof buf);
        if (n < 0) { fprintf(stderr, "encode: %s\n", opus_strerror(n)); return 1; }
        uint32_t len = (uint32_t)n;
        fwrite(&len, 4, 1, out); fwrite(buf, 1, n, out);
    }
    fclose(out);
    printf("wrote %d packets of %d frames with %s\n", PACKETS, FRAMES, opus_get_version_string());
    return 0;
}
