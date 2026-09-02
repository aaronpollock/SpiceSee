# Replacing the SPICE image codecs

SpiceSee's QUIC, LZ and GLZ decoders come from spice-common / spice-gtk and are licensed under
the GNU Lesser General Public License, version 2.1 or later. In line with LGPL-2.1 §6(b) they
ship as a separate dynamic framework you can replace with your own build. This page is the
information you need to do that. The framework's source, including the vendored files and the
record of what was changed (`Packages/CSpiceCodec/Sources/CSpiceCodec/VENDORED.md`), is at
https://github.com/aaronpollock/SpiceSee.

## What the app links

| | |
|---|---|
| Location in the bundle | `SpiceSee.app/Contents/Frameworks/CSpiceCodec.framework` |
| Install name | `@rpath/CSpiceCodec.framework/Versions/A/CSpiceCodec` |
| Bundle identifier | `cspicecodec.CSpiceCodec` |
| Architecture / OS | arm64, macOS 14.0 or later |
| Interface | the `sc_*` functions declared in `Packages/CSpiceCodec/Sources/CSpiceCodec/include/spice_codec.h` |

The app is signed with the hardened runtime and the
`com.apple.security.cs.disable-library-validation` entitlement, so it loads a framework that is
not signed by SpiceSee's developer — an ad hoc signature is enough.

## The interface

`spice_codec.h` is the whole ABI. The app calls, and your build must export with C linkage:

- QUIC: `sc_quic_create`, `sc_quic_destroy`, `sc_quic_begin`, `sc_quic_decode`, `sc_quic_encode_rgb32`
- LZ: `sc_lz_create`, `sc_lz_destroy`, `sc_lz_begin`, `sc_lz_decode`, `sc_lz_encode_rgb32`, `sc_lz_encode_xxxa`
- GLZ: `sc_glz_window_create`, `sc_glz_window_clear`, `sc_glz_window_destroy`, `sc_glz_create`, `sc_glz_destroy`, `sc_glz_decode`

with the `sc_image_type` enumeration and the semantics documented in the header (in particular:
every entry point returns non-zero on a corrupt stream instead of aborting, and `sc_glz_decode`'s
output buffer is owned by the window until the next decode). The framework as shipped also exports
its internal symbols (`_quic_decode`, `_spice_malloc`, …); the app uses none of them.

## Building a replacement

This one-line build was verified against the app's replay golden test on 2026-08-26:

```sh
cd Packages/CSpiceCodec/Sources/CSpiceCodec
clang -dynamiclib -arch arm64 -mmacosx-version-min=14.0 -O2 \
  -Ivendor -Ivendor/common -Ishim -Iinclude \
  codec_bridge.c vendor/common/quic.c vendor/common/lz.c vendor/common/mem.c vendor/decode-glz.c \
  -install_name @rpath/CSpiceCodec.framework/Versions/A/CSpiceCodec -o CSpiceCodec
```

## Installing it

1. Quit SpiceSee.
2. Copy your binary over
   `SpiceSee.app/Contents/Frameworks/CSpiceCodec.framework/Versions/A/CSpiceCodec`.
3. Re-sign the framework ad hoc:
   `codesign -f -s - SpiceSee.app/Contents/Frameworks/CSpiceCodec.framework`
4. Launch SpiceSee. Acknowledgements → "spice-common codecs" → *Show in Finder* opens the
   framework you just replaced.

Replacing the framework does not touch the app's own signature; Gatekeeper's first-launch check
of the downloaded app has already run. If you copy the modified app to another Mac, that Mac will
ask for confirmation once, as it does for any app whose contents changed after notarization.
