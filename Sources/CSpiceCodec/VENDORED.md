# Vendored sources

This directory contains third-party source copied verbatim into SpiceSee. It is the LGPL
source-publication record: every file below is listed with its upstream origin, revision, licence,
and any local modification. **A file on disk but missing from this list is a compliance failure** —
`scripts/check-vendored-notices.sh` enforces that, and must be re-run after any edit here and before
cutting a release.

Nothing in `vendor/` may be reformatted, re-indented, or hand-retyped. The header comments are the
licence grant, not decoration.

## Upstream revisions

| Project | Tag | Commit | Fetched |
|---|---|---|---|
| [spice-gtk](https://gitlab.freedesktop.org/spice/spice-gtk) | `v0.42` | `f04479c16f0969fb394ebe74b6eff74e560a42f0` | 2026-08-23 |
| spice-common (submodule of spice-gtk) | — | `58d375e5eadc6fb9e587e99fd81adcb95d01e8d6` | 2026-08-23 |
| [spice-protocol](https://gitlab.freedesktop.org/spice/spice-protocol) | `v0.14.3` | `90b57dace404db564a8e034ad4427b9951071bcd` | 2026-08-23 |

`spice-protocol` is not a submodule of spice-common at this revision — spice-gtk resolves it as an
external dependency (`spice_protocol_version = '0.14.3'` in `meson.build`), so it was cloned
separately at the version spice-gtk requires.

## Files

### From spice-common `common/` → `vendor/common/`

| File | Licence |
|---|---|
| `quic.c` | LGPL-2.1-or-later |
| `quic.h` | LGPL-2.1-or-later |
| `quic_config.h` | LGPL-2.1-or-later |
| `quic_family_tmpl.c` | LGPL-2.1-or-later |
| `quic_tmpl.c` | LGPL-2.1-or-later |
| `lz.c` | LGPL-2.1-or-later |
| `lz.h` | MIT (derived from [fastlz](http://www.fastlz.org/)) |
| `lz_common.h` | LGPL-2.1-or-later |
| `lz_config.h` | LGPL-2.1-or-later |
| `lz_compress_tmpl.c` | LGPL-2.1-or-later |
| `lz_decompress_tmpl.c` | LGPL-2.1-or-later |
| `macros.h` | LGPL-2.1-or-later |
| `verify.h` | LGPL-2.1-or-later |
| `draw.h` | BSD-3-Clause, © 2009 Red Hat |

The plan also listed `quic_rgb_tmpl.c` and `bitops.h`. Neither exists at this revision — the RGB
templates were folded into `quic_tmpl.c` upstream — so neither is vendored.

### From spice-gtk `src/` → `vendor/`

| File | Licence |
|---|---|
| `decode-glz.c` | LGPL-2.1-or-later |
| `decode-glz-tmpl.c` | LGPL-2.1-or-later |
| `decode.h` | LGPL-2.1-or-later |

### From spice-protocol `spice/` → `vendor/spice/`

| File | Licence |
|---|---|
| `macros.h` | LGPL-2.1-or-later |
| `types.h` | BSD-3-Clause, © 2009 Red Hat |
| `enums.h` | BSD-3-Clause, © 2009 Red Hat |
| `start-packed.h` | BSD-3-Clause, © 2009 Red Hat |
| `end-packed.h` | BSD-3-Clause, © 2009 Red Hat |
| `barrier.h` | BSD-3-Clause, © 2009 Red Hat |

`LICENSE.LGPL-2.1` is spice-gtk's `COPYING`, copied unmodified.

## Local modifications

None yet — recorded here as they are made.
