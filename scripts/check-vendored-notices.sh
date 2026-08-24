#!/bin/sh
# The LGPL position rests on these notices being intact and on VENDORED.md naming every file.
# Prints nothing and exits 0 when the vendored tree is compliant.
# Re-run after any edit under Sources/CSpiceCodec/vendor/ and before cutting a release.
cd "$(dirname "$0")/../Sources/CSpiceCodec" || exit 1
status=0
for f in $(find vendor -type f \( -name '*.c' -o -name '*.h' \)); do
  # lz.h carries only "(Distributed under MIT license)" upstream — no copyright line — so the
  # pattern has to accept a bare licence statement too.
  head -40 "$f" | grep -qiE 'copyright|SPDX-License-Identifier|General Public License|MIT license' \
    || { echo "STRIPPED NOTICE: $f"; status=1; }
done
[ -s LICENSE.LGPL-2.1 ] || { echo "MISSING: LICENSE.LGPL-2.1"; status=1; }
for f in $(find vendor -type f \( -name '*.c' -o -name '*.h' \)); do
  grep -q "$(basename "$f")" VENDORED.md || { echo "UNDISCLOSED: $f"; status=1; }
done
exit $status
