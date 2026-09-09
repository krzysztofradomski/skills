#!/usr/bin/env bash
# gif skill: sheet slicing, matte keying, sizing, the GIF format's own
# constraints (1-bit alpha, 10ms delays, one palette), and generation against a
# fake delegate.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
ROOT="$(dirname "$HERE")"
GIF="$ROOT/gif/scripts/gif.sh"
PY="${PYTHON:-python3}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if ! "$PY" -c "import PIL" >/dev/null 2>&1; then
  skip "gif tests need Pillow (pip install pillow)"; summary "gif"; exit $?
fi

# The fixture is generated rather than committed: a binary PNG in git tells you
# nothing in a diff, and this way the expected geometry is stated in code.
"$PY" - "$TMP" <<'PYGEN'
import math, sys
from PIL import Image, ImageDraw
tmp = sys.argv[1]
N, S = 8, 128
sheet = Image.new("RGB", (S * N, S), (255, 0, 255))     # the matte the skill keys out
d = ImageDraw.Draw(sheet)
for i in range(N):
    ang = 2 * math.pi * i / N
    cx, cy = S * i + S / 2 + math.cos(ang) * 20, S / 2 + math.sin(ang) * 20
    d.ellipse([cx - 30, cy - 30, cx + 30, cy + 30], fill=(30, 120, 220))
    d.rectangle([S * i + 20, S - 25, S * i + S - 20, S - 15], fill=(240, 200, 40))
sheet.save(tmp + "/sheet.png")
PYGEN
expect_file "$TMP/sheet.png" "generated the test sprite sheet"
"$PY" "$ROOT/gif/scripts/gifpack.py" slice "$TMP/sheet.png" "$TMP/frames" --cols 8 >/dev/null 2>&1

probe_field() { # file, field -> value
  "$GIF" probe "$1" 2>/dev/null | awk -v f="$2" '$1 == f { $1 = ""; sub(/^ +/, ""); print; exit }'
}

section "sizes and shape"
for z in 16 32 64 128; do
  run "$GIF" frames "$TMP/s$z.gif" "$TMP/frames" --size "$z"
  expect_ok "builds at ${z}x${z}"
  [ "$(probe_field "$TMP/s$z.gif" size)" = "${z}x${z}" ] \
    && pass "the file really is ${z}x${z}" || fail "the file really is ${z}x${z}"
done
run "$GIF" frames "$TMP/x.gif" "$TMP/frames" --size 48
expect_fail "refuses a size outside 16/32/64/128"

section "timing: the 10ms quantum"
run "$GIF" frames "$TMP/t1.gif" "$TMP/frames" --duration 1
# 1s over 8 frames is 12.5cs, which the format cannot store. The remainder is
# spread over the leading frames instead of rounded away, so the loop stays 1.00s.
expect_has "[130, 130, 130, 130, 120, 120, 120, 120]" "spreads an uneven remainder across frames"
expect_has "duration    1.00s" "and the loop still lasts exactly 1.00s"
run "$GIF" frames "$TMP/t2.gif" "$TMP/frames" --duration 3
expect_has "duration    3.00s" "3s is allowed"
run "$GIF" frames "$TMP/t3.gif" "$TMP/frames" --duration 3.5
expect_fail "over 3s is refused"
run "$GIF" frames "$TMP/t4.gif" "$TMP/frames" --duration 0.1
expect_fail "refuses a frame rate browsers would silently clamp"
expect_has "browsers clamp" "explaining the real limit"
expect_has "max 5" "and the frame count that would fit"

section "looping"
[ "$(probe_field "$TMP/t1.gif" loop)" = "forever" ] && pass "loops forever by default" || fail "loops forever by default"
run "$GIF" frames "$TMP/l.gif" "$TMP/frames" --loop 3
[ "$(probe_field "$TMP/l.gif" loop)" = "3" ] && pass "--loop N is written into the file" || fail "--loop N is written into the file"

section "transparency"
run "$GIF" frames "$TMP/tr.gif" "$TMP/frames" --size 32
expect_has "transparent yes" "keys the magenta matte out to transparency"
"$PY" - "$TMP/tr.gif" <<'PYCHK'
import sys
from PIL import Image
im = Image.open(sys.argv[1])
alpha = im.convert("RGBA").tobytes()[3::4]
# Corners must be gone and the subject must not be: a file that is entirely one
# or the other would still "have transparency" and be useless.
sys.exit(0 if alpha.count(0) > 200 and alpha.count(255) > 200 else 1)
PYCHK
[ $? -eq 0 ] && pass "the corners are transparent and the subject is not" \
             || fail "the corners are transparent and the subject is not"
run "$GIF" frames "$TMP/op.gif" "$TMP/frames" --bg "#222222"
expect_has "opaque" "--bg flattens onto a background instead"
[ "$(probe_field "$TMP/op.gif" transparent)" = "no" ] && pass "and the file carries no transparency" \
  || fail "and the file carries no transparency"
run "$GIF" frames "$TMP/fz.gif" "$TMP/frames" --fuzz 100
expect_fail "refuses to write a GIF the matte key emptied"
expect_has "fully transparent" "saying what happened"

section "sheet slicing"
run "$GIF" sheet "$TMP/sheet.png" "$TMP/sh.gif" --cols 8 --size 32
expect_ok "cuts a sheet into frames"
[ "$(probe_field "$TMP/sh.gif" frames)" = "8" ] && pass "8 columns give 8 frames" || fail "8 columns give 8 frames"
run "$GIF" sheet "$TMP/sheet.png" "$TMP/sh2.gif" --cols 5
expect_has "misaligned" "warns when the cells --cols implies are not square"
"$PY" - "$TMP" <<'PYGRID'
import sys
from PIL import Image
tmp = sys.argv[1]
# The same eight frames the model was asked to put in a row, laid out 4x2 as it often does.
row = Image.open(tmp + "/sheet.png")
S = row.height
grid = Image.new("RGB", (S * 4, S * 2), (255, 0, 255))
for i in range(8):
    grid.paste(row.crop((S * i, 0, S * (i + 1), S)), (S * (i % 4), S * (i // 4)))
grid.save(tmp + "/grid.png")
PYGRID
run "$GIF" sheet "$TMP/grid.png" "$TMP/sh4.gif"
expect_ok "reads a grid sheet without being told its shape"
expect_has "reading it as 4 x 2" "and says which layout it found"
[ "$(probe_field "$TMP/sh4.gif" frames)" = "8" ] && pass "8 frames, not 8 half-frames" \
  || fail "8 frames, not 8 half-frames"
[ "$(probe_field "$TMP/sh4.gif" transparent)" = "yes (index 63)" ] && pass "and the matte still keys out" \
  || fail "and the matte still keys out"

run "$GIF" sheet "$TMP/sheet.png" "$TMP/sh3.gif" --cols 4 --keep-frames "$TMP/kept"
expect_file "$TMP/kept/frame_00.png" "--keep-frames keeps the cut frames for re-cutting"

section "assembling your own frames"
run "$GIF" frames "$TMP/e.gif" "$TMP/frames/frame_00.png" "$TMP/frames/frame_01.png" "$TMP/frames/frame_02.png"
[ "$(probe_field "$TMP/e.gif" frames)" = "3" ] && pass "accepts explicit frame files" || fail "accepts explicit frame files"
run "$GIF" frames "$TMP/n.gif" "$TMP/frames/nope.png"
expect_fail "fails on a missing frame"
run "$GIF" frames "$TMP/id.gif" "$TMP/frames/frame_00.png" "$TMP/frames/frame_00.png"
# The encoder merges runs of identical frames and sums their delays, so the count
# reported has to come from the written file rather than from what we passed in.
expect_has "1 frame," "reports what the file holds, not what was passed in"
expect_has "1.00s" "with the duration preserved"

section "probe"
run "$GIF" probe "$TMP/t1.gif"
for f in "size" "frames" "duration" "loop" "transparent" "bytes"; do
  expect_has "$f" "probe reports $f"
done
run "$GIF" probe "$TMP/frames/frame_00.png"
expect_has "not a GIF" "probe flags a file that is not a GIF"

section "generation (fake delegate)"
FD="$TMP/fake"
make_fake_delegate "$FD" "$TMP/sheet.png"
run_sh "PATH='$FD/bin:$PATH' '$GIF' make 'a spinning coin' '$TMP/m.gif' --size 64 --duration 2 --keep-frames '$TMP/mk'"
expect_ok "make asks for one sheet and assembles it"
expect_has "64x64, 8 frames, 2.00s" "at the size and duration requested"
file_has "$FD/prompt-1.txt" "sprite sheet" "the prompt asks for a sprite sheet, not 8 images"
file_has "$FD/prompt-1.txt" "#FF00FF" "and for the matte it is about to key out"
file_has "$FD/tier-1.txt" "image" "using delegate's image verb"
expect_file "$TMP/mk/sheet.png" "--keep-frames keeps the sheet for re-cutting"
run_sh "PATH='/usr/bin:/bin' HOME='$TMP/nowhere' '$GIF' make 'x' '$TMP/m2.gif'"
expect_fail "make without delegate.sh fails"
expect_has "install the delegate skill" "pointing at the missing dependency"

summary "gif"
