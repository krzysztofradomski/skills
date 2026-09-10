#!/usr/bin/env bash
# delegate skill: provider detection, tier routing, the write-verification guard
# and its retry-on-confinement, the openrouter free-model fallback, skill
# application, and the free-before-paid image order. Runs against fake
# agy/codex/curl on PATH -- no real provider, network cost, or quota spent.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
ROOT="$(dirname "$HERE")"
DELEGATE="$ROOT/delegate/scripts/delegate.sh"

command -v jq >/dev/null 2>&1 || { skip "delegate tests need jq"; summary "delegate"; exit $?; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
# Strip any real agy/codex install from PATH first, so "missing" is genuinely
# missing even on a machine that has them -- this repo's own dev box does.
clean="$PATH"
for real in "$(command -v agy 2>/dev/null)" "$(command -v codex 2>/dev/null)"; do
  [ -n "$real" ] && clean="$(printf '%s\n' "$clean" | tr ':' '\n' | grep -vFx "$(dirname "$real")" | tr '\n' ':')"
done
export PATH="$BIN:${clean%:}"
export HOME="$TMP/home"; mkdir -p "$HOME"
WORK="$TMP/work"; mkdir -p "$WORK"

# A tiny real PNG, so the antigravity image path's `file -b` check passes.
FAKE_PNG="$TMP/fixture.png"
printf '%s' "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" \
  | { base64 -d 2>/dev/null || base64 -D; } > "$FAKE_PNG"
export FAKE_PNG

# Records what it was called with; "writes" into --add-dir only in write mode,
# and only when the model matches agy_writes_for ('*' = any model). That is
# how the write-confined-to-one-model retry is simulated: point agy_writes_for
# at M_WRITE and the tier model's own write attempt silently touches nothing.
make_fake_agy() {
  cat > "$BIN/agy" <<'FAKE'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")/.." && pwd)"
model=""; add_dir=""; prompt=""; write=0
args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    --model) i=$((i+1)); model="${args[$i]}" ;;
    --add-dir) i=$((i+1)); add_dir="${args[$i]}" ;;
    --mode) write=1; i=$((i+1)) ;;
    -p) i=$((i+1)); prompt="${args[$i]}" ;;
  esac
  i=$((i+1))
done
printf '%s' "$model" > "$d/last_model"
printf '%s' "$prompt" > "$d/last_prompt"
case "$prompt" in
  *generate_image*) b="$HOME/.gemini/antigravity-cli/brain/run1"; mkdir -p "$b"; cp "$FAKE_PNG" "$b/pic.png" ;;
esac
if [ "$write" = 1 ]; then
  target="$(cat "$d/agy_writes_for" 2>/dev/null || echo '*')"
  { [ "$target" = '*' ] || [ "$target" = "$model" ]; } && date +%s > "$add_dir/written-by-$model.txt"
fi
rc=0; [ -f "$d/agy_rc" ] && rc="$(cat "$d/agy_rc")"
echo "agy reply for $model"
exit "$rc"
FAKE
  chmod +x "$BIN/agy"
}

# Records the prompt, writes the -o output file, and "writes" into the
# workspace only in workspace-write sandbox mode (controlled by codex_writes).
make_fake_codex() {
  cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")/.." && pwd)"
case "$1" in
review) echo "fake review: no issues"; exit 0 ;;
exec)
  shift; sandbox=""; dir=""; out=""; prompt=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sandbox) shift; sandbox="$1"; shift ;;
      -C) shift; dir="$1"; shift ;;
      --skip-git-repo-check) shift ;;
      -o) shift; out="$1"; shift ;;
      *) prompt="$1"; shift ;;
    esac
  done
  printf '%s' "$prompt" > "$d/codex_last_prompt"
  [ -n "$out" ] && printf 'codex reply: %s\n' "$prompt" > "$out"
  if [ "$sandbox" = "workspace-write" ] && [ -n "$dir" ]; then
    writes="$(cat "$d/codex_writes" 2>/dev/null || echo 1)"
    [ "$writes" = 1 ] && date +%s > "$dir/codex-written.txt"
  fi
  exit "$(cat "$d/codex_rc" 2>/dev/null || echo 0)"
  ;;
esac
FAKE
  chmod +x "$BIN/codex"
}

# Answers /models, /key and /chat/completions. A model name containing
# "flaky" errors like a rate-limited free model, so or_free's walk-the-list
# fallback has something real to fall back from.
make_fake_curl() {
  cat > "$TMP/fake_models.json" <<'JSON'
{"data":[
  {"id":"flaky/free-model","pricing":{"prompt":"0","completion":"0"},"context_length":8000,"name":"Flaky"},
  {"id":"good/free-model","pricing":{"prompt":"0","completion":"0"},"context_length":8000,"name":"Good"}
]}
JSON
  cat > "$BIN/curl" <<CURL
#!/usr/bin/env bash
CTL="$TMP"
CURL
  cat >> "$BIN/curl" <<'FAKE'
url=""; data_stdin=0
args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    -K|-H) i=$((i+1)) ;;
    -d) i=$((i+1)); [ "${args[$i]}" = "@-" ] && data_stdin=1 ;;
    -s|-*) ;;
    *) url="${args[$i]}" ;;
  esac
  i=$((i+1))
done
body=""; [ "$data_stdin" = 1 ] && body="$(cat)"
case "$url" in
  */key)
    if [ "$(cat "$CTL/or_key_valid" 2>/dev/null)" = 1 ]; then printf '{"data":{"limit":100}}'
    else printf '{"error":{"message":"invalid api key"}}'; fi ;;
  */models) cat "$CTL/fake_models.json" ;;
  */chat/completions)
    model="$(printf '%s' "$body" | jq -r .model)"
    printf '%s' "$body" | jq -r '.messages[0].content' > "$CTL/or_last_prompt.txt"
    echo "$model" >> "$CTL/or_calls.log"
    case "$model" in
      *flaky*) printf '{"error":{"message":"rate limited","metadata":{"raw":"429 too many requests"}}}' ;;
      *) jq -n --arg c "REPLY from $model" '{choices:[{message:{content:$c}}]}' ;;
    esac ;;
  *) echo "fake curl: unhandled url $url" >&2; exit 1 ;;
esac
FAKE
  chmod +x "$BIN/curl"
}

section "providers"
run "$DELEGATE" providers
expect_has "antigravity  MISSING" "reports antigravity missing when agy is not on PATH"
expect_has "codex        MISSING" "reports codex missing when codex is not on PATH"
expect_has "openrouter   no key" "reports no openrouter key"
expect_has "ai-studio    no key" "reports no ai-studio key"
make_fake_agy; make_fake_codex; make_fake_curl
mkdir -p "$HOME/.codex"; echo '{"auth_mode":"chatgpt-plan"}' > "$HOME/.codex/auth.json"
run "$DELEGATE" providers
expect_has "antigravity  available" "reports antigravity available once agy is on PATH"
expect_has "chatgpt-plan" "and reads codex's real auth mode"
run_sh "OPENROUTER_API_KEY=fake-key '$DELEGATE' providers"
expect_has "key present (not verified" "an unchecked key is reported as present, not verified"
echo 1 > "$TMP/or_key_valid"
run_sh "OPENROUTER_API_KEY=fake-key '$DELEGATE' providers --check"
expect_ok "providers --check exits 0 on a real key"
expect_has "key valid" "and says so"
echo 0 > "$TMP/or_key_valid"
run_sh "OPENROUTER_API_KEY=fake-key '$DELEGATE' providers --check"
expect_fail "providers --check exits nonzero on a rejected key"
expect_has "KEY REJECTED" "and says it was rejected, not silently ignored"
run_sh "GEMINI_API_KEY=fake-key '$DELEGATE' providers"
expect_has "ai-studio    key present" "reports an ai-studio key once one is set"

section "tier routing"
run "$DELEGATE" code "do it" "$WORK"
expect_ok "code routes through agy"
[ "$(cat "$TMP/last_model")" = "claude-sonnet-4-6" ] \
  && pass "at the default M_CODE model" || fail "at the default M_CODE model" "$(cat "$TMP/last_model")"
run_sh "M_HARD=my-hard-model '$DELEGATE' hard 'do it' '$WORK'"
[ "$(cat "$TMP/last_model")" = "my-hard-model" ] \
  && pass "M_HARD overrides the model hard routes to" || fail "M_HARD overrides the model hard routes to"
run "$DELEGATE" read "do it" "$WORK"
[ "$(cat "$TMP/last_model")" = "gemini-3.7-flash-high" ] \
  && pass "read routes to the read-tier model" || fail "read routes to the read-tier model"
run "$DELEGATE" cheap "do it" "$WORK"
[ "$(cat "$TMP/last_model")" = "gemini-3.7-flash-low" ] \
  && pass "cheap routes to the cheap-tier model" || fail "cheap routes to the cheap-tier model"
run "$DELEGATE" antigravity "do it" "$WORK"
[ "$(cat "$TMP/last_model")" = "claude-sonnet-4-6" ] \
  && pass "bare antigravity defaults to the code-tier model" || fail "bare antigravity defaults to the code-tier model"
run_sh "AGY_MODEL=custom-model '$DELEGATE' agy 'do it' '$WORK'"
[ "$(cat "$TMP/last_model")" = "custom-model" ] \
  && pass "AGY_MODEL overrides the bare agy model" || fail "AGY_MODEL overrides the bare agy model"

section "skills applied to a prompt"
mkdir -p "$HOME/.gemini/antigravity/skills/askill"
run "$DELEGATE" code "explain this" "$WORK" --skill askill
expect_ok "a suggested skill that is installed succeeds"
file_has "$TMP/last_prompt" 'askill" skill is available and looks relevant' "and mentions it in the prompt"
file_has "$TMP/last_prompt" "explain this" "without dropping the original prompt"
run "$DELEGATE" code "explain this" "$WORK" --force-skill askill
expect_ok "a forced skill succeeds"
file_matches "$TMP/last_prompt" '^/askill ' "and slash-invokes it instead"
run "$DELEGATE" code "explain this" "$WORK" --skill nosuchskill
expect_fail "an uninstalled skill is refused"
expect_has "not installed for agy" "naming the provider it was checked against"

section "the write guard and its retry"
echo '*' > "$TMP/agy_writes_for"
run "$DELEGATE" code "add a file" "$WORK" --write
expect_ok "a model that actually writes succeeds first try"
expect_file "$WORK/written-by-claude-sonnet-4-6.txt" "and the file lands in the workspace"
rm -f "$WORK"/written-by-*
echo gemini-3.1-pro-high > "$TMP/agy_writes_for"
run "$DELEGATE" code "add a file" "$WORK" --write
expect_ok "a model confined to its own artifact dir still succeeds"
expect_has "retrying with gemini-3.1-pro-high" "because delegate notices nothing changed and retries on M_WRITE"
expect_file "$WORK/written-by-gemini-3.1-pro-high.txt" "and the retry is the one that actually wrote"
rm -f "$WORK"/written-by-*
echo nobody-writes-this > "$TMP/agy_writes_for"
run "$DELEGATE" code "add a file" "$WORK" --write
expect_fail "even the retry writing nothing is reported as failure, not success"
expect_has "changed nothing" "rather than trusting the model's own claim"
echo '*' > "$TMP/agy_writes_for"

section "codex"
run "$DELEGATE" codex "summarize this" "$WORK"
expect_ok "codex runs and returns its reply"
expect_has "summarize this" "the reply reflects the prompt it was given"
echo 1 > "$TMP/codex_writes"
run "$DELEGATE" codex "add a file" "$WORK" --write
expect_ok "codex --write succeeds when the workspace actually changed"
echo 0 > "$TMP/codex_writes"
run "$DELEGATE" codex "add a file" "$WORK" --write
expect_fail "codex --write fails when nothing changed, the same guard as agy"
expect_has "changed nothing" "rather than trusting a false success"
echo 1 > "$TMP/codex_writes"

section "openrouter (or)"
echo 1 > "$TMP/or_key_valid"
run_sh "OPENROUTER_API_KEY=fake-key '$DELEGATE' or 'hello there' good/free-model"
expect_ok "a pinned model is used directly"
expect_has "REPLY from good/free-model" "and its answer comes back"
run_sh "OPENROUTER_API_KEY=fake-key '$DELEGATE' or 'hello there'"
expect_ok "auto picks from the free-model list"
expect_has "flaky/free-model unavailable, trying next" "walking past a model that errors"
expect_has "REPLY from good/free-model" "to the next one, which answers"
mkdir -p "$HOME/.claude/skills/testskill"
echo "SKILL-MARKER-TEXT" > "$HOME/.claude/skills/testskill/SKILL.md"
run_sh "OPENROUTER_API_KEY=fake-key '$DELEGATE' or 'do the thing' good/free-model --skill testskill"
expect_ok "or --skill succeeds when the skill file exists"
file_has "$TMP/or_last_prompt.txt" "SKILL-MARKER-TEXT" "and inlines the skill's own text into the prompt"
run_sh "OPENROUTER_API_KEY=fake-key '$DELEGATE' or 'do the thing' good/free-model --skill nosuchskill"
expect_fail "or --skill fails when the skill file does not exist"
expect_has "not found" "naming what was looked for, not a raw file error"

section "listing installed skills"
mkdir -p "$HOME/.codex/skills/cskill"
run "$DELEGATE" skills
expect_has "--- agy:" "lists the agy section"
expect_has "askill" "with what's installed for it"
expect_has "--- codex:" "lists the codex section"
expect_has "cskill" "with what's installed for it"
run "$DELEGATE" skills agy
expect_ok "a single provider can be listed alone"
expect_has "askill" "and shows just that one's skills"

section "guards"
run "$DELEGATE" code "do it" /no/such/dir
expect_fail "refuses a directory that does not exist"
expect_has "not a directory" "and says so"
run "$DELEGATE" code "do it" "$WORK" --nope
expect_fail "refuses an unknown option"
expect_has "unknown option" "and names it"
run "$DELEGATE"
expect_fail "refuses to run with no verb"
expect_has "usage:" "and prints usage"

section "timeout guard"
# A provider that never returns at all -- not even a nonzero exit, just silence -- is the exact
# shape that used to hang svg.sh/gif.sh forever with nothing to interrupt it. Backgrounding the
# sleep and waiting on it (rather than a plain foreground `sleep`) also means a broken guard that
# only kills the top process, not its children, would still leave this hung.
cat > "$BIN/agy" <<'FAKE'
#!/usr/bin/env bash
sleep 3600 &
wait
FAKE
chmod +x "$BIN/agy"
start=$(date +%s)
run_sh "DELEGATE_TIMEOUT=2 '$DELEGATE' code 'do it' '$WORK'"
elapsed=$(( $(date +%s) - start ))
expect_fail "a provider that never returns is killed rather than hung on forever"
[ "$elapsed" -le 15 ] && pass "and control comes back within the configured budget" \
  || fail "and control comes back within the configured budget" "took ${elapsed}s (budget was 2s)"
sleep 1  # let the killed process's own children (if any leaked) show up in ps before we check
pgrep -f "sleep 3600" >/dev/null \
  && fail "does not leave the hung provider's own children running" "found a leaked 'sleep 3600'" \
  || pass "does not leave the hung provider's own children running"
make_fake_agy   # restore the normal, fast fake for anything after this point

section "images: free before paid"
rm -rf "$HOME/.gemini"
run "$DELEGATE" image "a green leaf" "$TMP/out/leaf.png"
expect_ok "antigravity's free image path succeeds"
expect_has "(antigravity, free)" "and says which free path served it"
expect_file "$TMP/out/leaf.png" "with the file actually on disk"
rm -f "$BIN/agy" "$BIN/codex"
run_sh "OPENROUTER_API_KEY= GEMINI_API_KEY= '$DELEGATE' image 'a cat' '$TMP/out/cat.png'"
expect_fail "with no provider at all, it refuses rather than silently spending money"
expect_has "--paid" "and says paid providers need the explicit flag"

summary "delegate"
