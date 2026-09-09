#!/usr/bin/env bash
# install.sh: linking, idempotency, and the guarantees it makes about not
# clobbering things it does not own. Runs against a clone of the working tree in
# a temp directory -- it never touches your real ~/.claude.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
ROOT="$(dirname "$HERE")"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if [ ! -d "$ROOT/.git" ]; then skip "install tests need a git clone"; summary "install"; exit $?; fi

install_into() { # dest-root, extra args...
  local d="$1"; shift
  run_sh "SKILLS_REPO='$ROOT' SKILLS_DIR='$d/clone' CLAUDE_DIR='$d/.claude/skills' \
          CODEX_DIR='$d/.codex/skills' BIN_DIR='$d/bin' bash '$ROOT/install.sh' $*"
}

section "installing everything"
# Regression: `available` used to return 1 when the last directory had no
# SKILL.md (site/), so the NUL its caller needed was never printed and `set -e`
# killed an argument-less run before it linked anything.
install_into "$TMP/a"
expect_ok "a bare 'bash install.sh' succeeds"
for s in delegate gif svg; do
  [ -L "$TMP/a/.claude/skills/$s" ] && pass "links $s into the Claude skill dir" \
    || fail "links $s into the Claude skill dir"
done
for b in delegate.sh gif.sh svg.sh; do
  [ -L "$TMP/a/bin/$b" ] && pass "puts $b on PATH" || fail "puts $b on PATH"
done
[ -e "$TMP/a/bin/gifpack.py" ] && fail "helper scripts stay off PATH" \
  || pass "helper scripts stay off PATH (only the executables are linked)"
[ -e "$TMP/a/.claude/skills/site" ] && fail "site/ is not a skill" || pass "site/ is not treated as a skill"

section "the linked scripts actually run"
run_sh "PATH=$TMP/a/bin:\$PATH svg.sh check"
expect_ok "svg.sh runs through its symlink"
expect_has "svgpack.py" "and resolves the link chain to find its helper"
run_sh "PATH=$TMP/a/bin:\$PATH gif.sh check"
expect_ok "gif.sh runs through its symlink"
expect_has "gifpack.py" "and finds its helper too"

section "subsets and re-runs"
install_into "$TMP/b" gif
expect_ok "installing a named subset succeeds"
[ -L "$TMP/b/.claude/skills/gif" ] && pass "links the one asked for" || fail "links the one asked for"
[ -e "$TMP/b/.claude/skills/svg" ] && fail "and nothing else" || pass "and nothing else"
install_into "$TMP/b" nosuchskill
expect_fail "an unknown skill name fails"
expect_has "no such skill" "listing what is available"
install_into "$TMP/a"
expect_ok "re-running updates in place"
expect_has "already linked" "and says the links are already there"

section "it never clobbers what it does not own"
mkdir -p "$TMP/c/.claude/skills/gif"; touch "$TMP/c/.claude/skills/gif/mine.md"
install_into "$TMP/c"
expect_ok "a real directory in the way does not stop the run"
expect_has "not a symlink -- skipped" "it is skipped with a warning"
expect_file "$TMP/c/.claude/skills/gif/mine.md" "and the existing files are untouched"

summary "install"
