# Minimal test helpers. No framework, no dependencies: these suites have to run
# from a clone on a machine that has just installed the skills.
# shellcheck shell=bash

PASS=0; FAIL=0; SKIP=0; CURRENT=""
OUT=""; RC=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_NO=$'\033[31m'; C_SK=$'\033[33m'; C_DIM=$'\033[2m'; C_Z=$'\033[0m'
else
  C_OK=""; C_NO=""; C_SK=""; C_DIM=""; C_Z=""
fi

section() { CURRENT="$1"; printf '\n%s--- %s%s\n' "$C_DIM" "$1" "$C_Z"; }
pass() { PASS=$((PASS + 1)); printf '  %sok%s   %s\n' "$C_OK" "$C_Z" "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  %sskip%s %s\n' "$C_SK" "$C_Z" "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf '  %sFAIL%s %s\n' "$C_NO" "$C_Z" "$1"
  [ -n "${2:-}" ] && printf '       %s\n' "$2"
  # The captured output is nearly always the explanation, so print it rather than
  # making whoever hit this re-run the command by hand.
  [ -n "$OUT" ] && printf '%s\n' "$OUT" | sed 's/^/       | /' | head -12
  return 0
}

# Run a command, capturing status and combined output for the assertions below.
run() { OUT="$("$@" 2>&1)"; RC=$?; return 0; }
run_sh() { OUT="$(eval "$1" 2>&1)"; RC=$?; return 0; }

expect_rc()   { [ "$RC" = "$1" ] && pass "$2" || fail "$2" "expected exit $1, got $RC"; }
expect_ok()   { expect_rc 0 "$1"; }
expect_fail() { [ "$RC" != 0 ] && pass "$1" || fail "$1" "expected a nonzero exit"; }
expect_has()  { case "$OUT" in *"$1"*) pass "$2" ;; *) fail "$2" "output does not contain: $1" ;; esac; }
expect_lacks(){ case "$OUT" in *"$1"*) fail "$2" "output should not contain: $1" ;; *) pass "$2" ;; esac; }
expect_file() { [ -f "$1" ] && pass "$2" || fail "$2" "no such file: $1"; }

# Assertions against a file's contents rather than a command's output.
file_has()   { if grep -qF -- "$2" "$1"; then pass "$3"; else fail "$3" "$1 lacks: $2"; fi; }
file_lacks() { if grep -qiF -- "$2" "$1"; then fail "$3" "$1 still contains: $2"; else pass "$3"; fi; }
file_matches()   { if grep -qE -- "$2" "$1"; then pass "$3"; else fail "$3" "$1 does not match: $2"; fi; }

summary() {
  printf '\n%s: %s%d passed%s, %s%d failed%s, %d skipped\n' \
    "${1:-tests}" "$C_OK" "$PASS" "$C_Z" "$([ "$FAIL" -gt 0 ] && echo "$C_NO")" "$FAIL" "$C_Z" "$SKIP"
  [ "$FAIL" -eq 0 ]
}

# A stand-in for delegate.sh that replays canned replies in order and records the
# prompt it was handed. Lets the generation path be tested without a provider,
# a network, or a cent of anyone's quota -- including the retry loop, which needs
# a first reply that is deliberately wrong.
make_fake_delegate() { # dir, reply-file...
  local dir="$1"; shift
  mkdir -p "$dir/bin"
  local i=1
  for r in "$@"; do cp "$r" "$dir/reply-$i.txt"; i=$((i + 1)); done
  echo 1 > "$dir/n"
  cat > "$dir/bin/delegate.sh" <<'FAKE'
#!/usr/bin/env bash
# Replays fixtures as if it were delegate.sh: $1 verb, $2 prompt, $3 out-path.
d="$(cd "$(dirname "$0")/.." && pwd)"
n="$(cat "$d/n" 2>/dev/null || echo 1)"
echo "$((n + 1))" > "$d/n"
printf '%s\n' "$2" > "$d/prompt-$n.txt"
printf '%s\n' "$1" > "$d/tier-$n.txt"
[ -f "$d/reply-$n.txt" ] || { echo "fake delegate: no reply #$n" >&2; exit 3; }
case "$1" in
  image) cp "$d/reply-$n.txt" "$3" ;;   # the image verb writes a file
  *)     cat "$d/reply-$n.txt" ;;       # text verbs answer on stdout
esac
FAKE
  chmod +x "$dir/bin/delegate.sh"
}
