#!/usr/bin/env bash
# svg skill: sanitizing, normalizing, retiming, frame sequences, and the
# generate-and-retry loop (against a fake delegate, so no provider is involved).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
ROOT="$(dirname "$HERE")"
SVG="$ROOT/svg/scripts/svg.sh"
FIX="$HERE/fixtures/svg"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

section "extraction"
run "$SVG" build "$TMP/a.svg" "$FIX/animated-css.txt"
expect_ok "pulls the SVG out of prose and a markdown fence"
file_lacks "$TMP/a.svg" "Let me know" "prose does not survive into the file"
run "$SVG" build "$TMP/b.svg" "$FIX/no-svg.txt"
expect_fail "fails when the reply contains no SVG at all"
expect_has "no <svg> element" "says why"
run_sh "cat '$FIX/animated-css.txt' | '$SVG' build '$TMP/c.svg' -"
expect_ok "reads the reply from stdin"

section "safety"
run "$SVG" build "$TMP/clean.svg" "$FIX/hostile.txt" --size 32
expect_ok "builds from a hostile reply instead of dying"
expect_has "stripped unsafe or external content" "says what it stripped"
for bad in "<script" "onload" "onclick" "javascript:" "evil.example" "foreignObject" "@import"; do
  file_lacks "$TMP/clean.svg" "$bad" "strips $bad"
done
file_has "$TMP/clean.svg" 'href="#nothing"' "keeps internal #fragment references"
run "$SVG" build "$TMP/xxe.svg" "$FIX/doctype.txt"
expect_fail "refuses a DOCTYPE/ENTITY declaration"
expect_has "refusing to parse" "and says so rather than parsing it anyway"
run "$SVG" probe "$FIX/hostile.txt"
expect_fail "probe exits nonzero on an unsafe file (so it lints foreign SVGs)"
expect_has "unsafe" "and names what it found"

section "geometry"
run "$SVG" build "$TMP/g.svg" "$FIX/animated-smil.txt" --size 128
file_matches "$TMP/g.svg" 'width="128"' "sets width to --size"
file_has "$TMP/g.svg" 'viewBox="0 0 100 100"' "keeps the model's viewBox as the drawing space"
expect_has "removed 1 full-canvas background rect" "removes the backdrop the model drew"
run "$SVG" build "$TMP/bg.svg" "$FIX/animated-smil.txt" --bg "#0b1020"
file_matches "$TMP/bg.svg" '<rect[^>]*fill="#0b1020"' "inserts one full-canvas rect for --bg"
run "$SVG" build "$TMP/nx.svg" "$FIX/no-xmlns.txt"
expect_ok "accepts a reply with no xmlns"
file_has "$TMP/nx.svg" 'xmlns="http://www.w3.org/2000/svg"' "and adds the namespace"
run "$SVG" build "$TMP/r.svg" "$FIX/animated-smil.txt" --size 64
file_lacks "$TMP/r.svg" "28.123456" "rounds long coordinates"
run "$SVG" build "$TMP/nr.svg" "$FIX/animated-smil.txt" --round -1
file_has "$TMP/nr.svg" "28.123456" "--round -1 leaves them alone"

section "timing: one loop is exactly --duration"
# The fixture animates for 1.2s with the third element delayed 0.4s. The loop
# period is the duration, not duration+delay: a repeating animation restarts
# every dur, so the delay is a phase shift inside the loop. Anchoring on the sum
# is what used to make a staggered loader run faster than asked.
run "$SVG" build "$TMP/t1.svg" "$FIX/animated-smil.txt" --duration 1
file_has "$TMP/t1.svg" 'dur="1s"' "SMIL: scales dur to the requested loop"
file_has "$TMP/t1.svg" 'begin="0.3333s"' "SMIL: keeps the delay at the same fraction of the loop"
run "$SVG" build "$TMP/t2.svg" "$FIX/animated-smil.txt" --duration 3
file_has "$TMP/t2.svg" 'dur="3s"' "SMIL: and again at a different duration"
file_has "$TMP/t2.svg" 'begin="1s"' "SMIL: phase scales with it"
run "$SVG" build "$TMP/t3.svg" "$FIX/animated-css.txt" --duration 1
file_has "$TMP/t3.svg" "bounce 1s" "CSS: scales animation-duration"
file_has "$TMP/t3.svg" "animation-delay: 0.1667s" "CSS: keeps the stagger proportional"
file_has "$TMP/t3.svg" "animation-delay: 0.3333s" "CSS: for every delayed element"
run "$SVG" probe "$TMP/t3.svg"
expect_has "cycle 1.000s" "probe reports the real cycle"

section "looping and reduced motion"
run "$SVG" build "$TMP/l1.svg" "$FIX/animated-smil.txt"
file_has "$TMP/l1.svg" 'repeatCount="indefinite"' "forces SMIL repeatCount (without it it plays once)"
run "$SVG" build "$TMP/l2.svg" "$FIX/animated-smil.txt" --loop 3
file_has "$TMP/l2.svg" 'repeatCount="3"' "--loop N is honoured"
run "$SVG" build "$TMP/l3.svg" "$FIX/animated-css.txt"
file_has "$TMP/l3.svg" "animation-iteration-count: infinite" "forces the CSS iteration count"
file_has "$TMP/l3.svg" "prefers-reduced-motion" "adds a reduced-motion rule"
run "$SVG" build "$TMP/l4.svg" "$FIX/animated-css.txt" --no-reduced-motion
file_lacks "$TMP/l4.svg" "prefers-reduced-motion" "--no-reduced-motion omits it"

section "--still"
run "$SVG" build "$TMP/s1.svg" "$FIX/animated-css.txt" --still
expect_ok "builds a still from an animated reply"
file_lacks "$TMP/s1.svg" "@keyframes" "removes the keyframes"
file_lacks "$TMP/s1.svg" "animation:" "and the animation declarations"
run "$SVG" build "$TMP/s2.svg" "$FIX/animated-smil.txt" --still
file_lacks "$TMP/s2.svg" "<animate" "removes SMIL elements too"
run "$SVG" probe "$TMP/s2.svg"
expect_has "none (still)" "probe calls it still"
run "$SVG" build "$TMP/s3.svg" "$FIX/static.txt"
expect_fail "rejects a static reply when an animation was asked for"
expect_has "no animation in the SVG" "and says which flag would accept it"

section "--frames"
run "$SVG" build "$TMP/f.svg" "$FIX/frames-4.txt" --frames 4 --duration 1 --keep-frames "$TMP/frames"
expect_ok "assembles 4 drawings into a frame sequence"
expect_has "4-frame sequence" "reports the mode"
file_has "$TMP/f.svg" "step-end" "holds each frame instead of cross-fading"
file_has "$TMP/f.svg" "25%" "each frame owns 100/N percent of the cycle"
file_has "$TMP/f.svg" "animation-delay: -0.25s" "offsets frame 1 by one slot"
file_has "$TMP/f.svg" "animation-delay: -0.75s" "and frame 3 by three"
file_has "$TMP/f.svg" "spk-frame-0" "tags the frames for the generated CSS"
for i in 00 01 02 03; do expect_file "$TMP/frames/f_$i.svg" "writes still frame $i"; done
file_lacks "$TMP/frames/f_00.svg" "animation" "the stills carry no animation"
run "$SVG" build "$TMP/f2.svg" "$FIX/frames-4.txt" --frames 6
expect_fail "rejects a reply with the wrong number of frame groups"
expect_has "found 4" "and says what it found"
run "$SVG" build "$TMP/f3.svg" "$FIX/frames-4.txt" --frames 4 --still
expect_fail "--still and --frames are mutually exclusive"

section "guards"
run "$SVG" build "$TMP/x.svg" "$FIX/animated-css.txt" --size 48
expect_fail "refuses a size outside 16/32/64/128"
run "$SVG" build "$TMP/x.svg" "$FIX/animated-css.txt" --duration 4
expect_fail "refuses a duration over 3s"
run "$SVG" build "$TMP/x.svg" "$FIX/animated-css.txt" --bg "not-a-color"
expect_fail "refuses a nonsense colour"
run "$SVG" make "x" "$TMP/x.svg" --tier gpt9
expect_fail "refuses an unknown delegate tier"
run "$SVG" build "$TMP/x.svg" "$FIX/animated-css.txt" --nope
expect_fail "refuses an unknown option"

section "generation and the retry loop (fake delegate)"
FD="$TMP/fake"
# First reply is static, which the animated default must reject; the retry then
# gets a usable one. This is the loop that costs plan allowance instead of context.
make_fake_delegate "$FD" "$FIX/static.txt" "$FIX/animated-css.txt"
run_sh "PATH='$FD/bin:$PATH' '$SVG' make 'a bell' '$TMP/m.svg' --size 64 --duration 1.5 --keep-raw '$TMP/raw.txt'"
expect_ok "make succeeds on the second attempt"
expect_has "retry 1/1" "reports the retry"
expect_has "64x64" "and the finished file"
file_has "$FD/tier-1.txt" "code" "first attempt uses the default tier"
file_has "$FD/tier-2.txt" "hard" "the retry escalates a tier"
file_has "$FD/prompt-2.txt" "previous attempt was rejected" "the retry hands the model its own error"
file_has "$FD/prompt-1.txt" "Animate it with CSS" "the default prompt asks for CSS"
file_has "$FD/prompt-1.txt" "1.5s" "and states the loop length it will be held to"
expect_file "$TMP/raw.txt" "--keep-raw keeps the reply"

make_fake_delegate "$FD" "$FIX/animated-smil.txt"
run_sh "PATH='$FD/bin:$PATH' '$SVG' make 'a coin' '$TMP/m2.svg' --smil"
expect_ok "--smil generates too"
file_has "$FD/prompt-1.txt" "SMIL" "and asks for SMIL instead"

make_fake_delegate "$FD" "$FIX/frames-4.txt"
run_sh "PATH='$FD/bin:$PATH' '$SVG' still 'a bell' '$TMP/m3.svg'"
expect_ok "the still verb works"
file_has "$FD/prompt-1.txt" "STILL image" "and asks for a static drawing"

make_fake_delegate "$FD" "$FIX/static.txt" "$FIX/static.txt"
run_sh "PATH='$FD/bin:$PATH' '$SVG' make 'a bell' '$TMP/m4.svg'"
expect_fail "gives up after the retries are spent"
expect_has "could not get a usable SVG" "with advice rather than a stack trace"

run_sh "PATH='/usr/bin:/bin' HOME='$TMP/nowhere' '$SVG' make 'x' '$TMP/m5.svg'"
expect_fail "make without delegate.sh fails"
expect_has "install the delegate skill" "pointing at the missing dependency"
run "$SVG" build "$TMP/nodel.svg" "$FIX/animated-css.txt"
expect_ok "but build/probe/preview never need delegate"

summary "svg"
