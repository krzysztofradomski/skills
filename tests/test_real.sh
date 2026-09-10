#!/usr/bin/env bash
# Opt-in regression check against a REAL provider (agy/codex) -- spends real plan allowance,
# unlike every other suite here which runs against fake agy/codex/curl stubs on PATH. Not part of
# the default `run.sh` set; run it explicitly:
#   bash tests/run.sh real
#   bash tests/test_real.sh
# Catches the class of bug the fake suites structurally cannot: a real CLI flag renamed, a real
# reply shaped differently than the stub assumes, or the timeout guard misfiring against an
# actually-slow network round trip instead of a sleeping fake.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
ROOT="$(dirname "$HERE")"
DELEGATE="$ROOT/delegate/scripts/delegate.sh"
SVG="$ROOT/svg/scripts/svg.sh"
GIF="$ROOT/gif/scripts/gif.sh"

[ -x "$DELEGATE" ] || { skip "delegate.sh not found"; summary "real"; exit $?; }
prov="$("$DELEGATE" providers 2>&1)"
case "$prov" in
  *"antigravity  available"*|*"codex        available"*) ;;
  *) skip "no real provider installed (agy/codex) -- see: delegate.sh providers"; summary "real"; exit $? ;;
esac

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

section "delegate against a real provider"
run "$DELEGATE" cheap "Reply with exactly the word: pong"
expect_ok "a cheap-tier call to a real provider succeeds"
expect_has "pong" "and the real model actually answered the prompt"

section "svg against a real provider"
run "$SVG" still "a small red circle" "$TMP/circle.svg"
expect_ok "svg.sh still generates from a real model"
expect_file "$TMP/circle.svg" "and writes the file"
expect_has "unsafe      none" "and the sanitizer finds nothing to strip"

run "$SVG" make "a pulsing dot" "$TMP/pulse.svg" --duration 1
expect_ok "svg.sh make (animated) generates from a real model"
expect_has "animation   CSS" "and the animation actually made it into the file"

section "gif against a real provider"
run "$GIF" make "a bouncing ball" "$TMP/ball.gif" --size 32
expect_ok "gif.sh make generates from a real model"
expect_file "$TMP/ball.gif" "and writes the file"

section "the timeout guard against a real (deliberately too-slow) provider"
# 1s is not enough for even a fast CLI to start up and round-trip a real network call, so this
# should always trip the guard -- proving it fires against genuine latency, not just a fake sleep.
start=$(date +%s)
run_sh "DELEGATE_TIMEOUT=1 '$DELEGATE' cheap 'reply with the word: pong'"
elapsed=$(( $(date +%s) - start ))
expect_fail "a 1s budget is not enough for a real round trip, so it is killed"
[ "$elapsed" -le 20 ] && pass "and the caller gets control back quickly, not hung" \
  || fail "and the caller gets control back quickly, not hung" "took ${elapsed}s"

summary "real"
