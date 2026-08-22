#!/usr/bin/env bash
# Route work to a cheaper provider. Antigravity/Codex = plan allowance, OpenRouter = API key.
set -euo pipefail

CODEX="$(command -v codex || echo "$HOME/.codex/plugins/.plugin-appserver/codex")"
AGY="$(command -v agy || command -v antigravity || echo "$HOME/.local/bin/agy")"
OR_KEY="${OPENROUTER_API_KEY:-$(cat "$HOME/.config/openrouter/key" 2>/dev/null || true)}"
OR_URL="https://openrouter.ai/api/v1"
GK="${GEMINI_API_KEY:-$(cat "$HOME/.config/google-ai/key" 2>/dev/null || true)}"
G_URL="https://generativelanguage.googleapis.com/v1beta/models"

# Antigravity model tiers. 3rd-party (Claude) reason better about code; 1st-party (Gemini) is
# faster and cheaper for reading/searching. Override any of them from the environment.
M_HARD="${M_HARD:-claude-opus-4-6-thinking}"   # cross-cutting, subtle, hard to reverse
M_CODE="${M_CODE:-claude-sonnet-4-6}"          # ordinary implementation
M_READ="${M_READ:-gemini-3.7-flash-high}"      # read/search/summarize a tree
M_CHEAP="${M_CHEAP:-gemini-3.7-flash-low}"     # trivial one-liners
# Some models' write tool is hard-confined to their own artifact dir (claude-sonnet-4-6 fails this
# way, intermittently, no matter how the prompt is worded). --write retries once on this model.
M_WRITE="${M_WRITE:-gemini-3.1-pro-high}"

die() { echo "delegate: $*" >&2; exit 2; }

# Review must come from a different vendor than the agent that wrote the code, so the reviewer is
# chosen against whichever CLI we are running inside.
host_agent() {
  if [ -n "${CODEX_SESSION_ID:-}${CODEX_THREAD_ID:-}" ]; then echo codex
  elif [ -n "${CLAUDE_CODE_ENTRYPOINT:-}${CLAUDECODE:-}" ]; then echo claude
  else echo unknown; fi
}

# BSD/macOS and GNU/Linux disagree on these three; pick whichever the host actually has.
mtime_name() { stat -f '%m %N' "$@" 2>/dev/null || stat -c '%Y %n' "$@" 2>/dev/null; }
b64d() { base64 -d 2>/dev/null || base64 -D; }
to_png() { # src, dest -- returns nonzero if no converter is available or conversion fails
  if command -v sips >/dev/null; then sips -s format png "$1" --out "$2" >/dev/null 2>&1
  elif command -v magick >/dev/null; then magick "$1" "$2" >/dev/null 2>&1
  elif command -v convert >/dev/null; then convert "$1" "$2" >/dev/null 2>&1
  else return 1; fi
}

# Every temp file lives here so one trap cleans them all, even on failure or Ctrl-C.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
trap 'rm -rf "$TMP"; exit 130' INT
trap 'rm -rf "$TMP"; exit 143' TERM

# Keys must not land in argv, where any local process can read them off `ps`. curl -K takes them
# from a 0600 config file instead; the body still arrives on stdin as -d @-.
curl_key() { # header-line, curl args... ; body on stdin
  local cfg; cfg="$(mktemp "$TMP/cfg.XXXXXX")"; chmod 600 "$cfg"
  printf 'header = "%s"\n' "$1" > "$cfg"; shift
  curl -s -K "$cfg" "$@"
}

# Zero-priced OpenRouter models, best-first. `:free` alone misses stealth/*, which is where the
# cloaked frontier models live -- match on price, not on the id suffix.
free_models() {
  curl -s "$OR_URL/models" | jq -r '
    [ .data[]
      | select(.pricing.prompt=="0" and .pricing.completion=="0")
      | select(.id|test("lyria|openrouter/free")|not)          # music models and the meta-router
      | . + {rank: (if (.id|startswith("stealth/")) then 0     # cloaked frontier, prefer these
                    elif (.id|test("ultra|glm|inkling|dots|laguna|north|super")) then 1
                    else 2 end)} ]
    | sort_by(.rank, -.context_length)
    | .[] | "\(.id)\tctx=\(.context_length)\t\(.name)"'
}

or_chat() { # model, prompt
  [ -n "$OR_KEY" ] || die "no OPENROUTER_API_KEY (env or ~/.config/openrouter/key)"
  jq -n --arg m "$1" --arg p "$2" '{model:$m,messages:[{role:"user",content:$p}]}' \
  | curl_key "Authorization: Bearer $OR_KEY" "$OR_URL/chat/completions" \
      -H 'Content-Type: application/json' -d @- \
  | jq -r 'if .error then "ERROR: \(.error.message) [\(.error.metadata.raw // "no detail")]"|halt_error(1)
           else .choices[0].message.content end'
}

# Free pools 429 constantly, so walk best-first until one answers.
or_free() { # prompt
  local m err
  for m in $(free_models | head -4 | cut -f1); do
    if err="$(or_chat "$m" "$1" 2>&1)"; then printf '%s\n' "$err"; return 0; fi
    echo "[delegate] $m unavailable, trying next" >&2
  done
  echo "all free models failed; last: ${err:-none}" >&2; return 1
}

# --write, --skill and [dir] are all optional and may arrive in any order, so parse rather than
# positionally index -- treating a flag as a directory is how this broke before.
DIR="$PWD"; WRITE=""; SKILL=""; SKILL_FORCE=""
parse_opts() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --write) WRITE="--write"; shift ;;
      --skill) SKILL="${2:?--skill needs a skill name}"; shift 2 ;;
      --force-skill) SKILL="${2:?--force-skill needs a skill name}"; SKILL_FORCE=1; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) DIR="$1"; shift ;;
    esac
  done
  [ -d "$DIR" ] || die "not a directory: $DIR"
  DIR="$(cd "$DIR" && pwd)"
}

# Each provider ships its own skill set and they barely overlap, so a skill must be checked
# against the provider that will actually run it.
skill_dir() { case "$1" in
  agy)   echo "$HOME/.gemini/antigravity/skills" ;;
  codex) echo "$HOME/.codex/skills" ;;
esac; }
list_skills() { # provider
  local d; d="$(skill_dir "$1")"
  [ -d "$d" ] || { echo "(no skill dir for $1)"; return; }
  { ls "$d" 2>/dev/null || true; ls "$d/.system" 2>/dev/null || true; } | grep -v '^\.' | sort -u || true
}
# suggest -> mention it and let the model judge; force -> slash-invoke it, which both CLIs expand.
apply_skill() { # provider, prompt
  local prov="$1" p="$2" d
  [ -n "$SKILL" ] || { printf '%s' "$p"; return; }
  d="$(skill_dir "$prov")"
  [ -d "$d/$SKILL" ] || [ -d "$d/.system/$SKILL" ] \
    || die "skill '$SKILL' is not installed for $prov (list them: delegate.sh skills $prov)"
  if [ -n "$SKILL_FORCE" ]; then printf '/%s %s' "$SKILL" "$p"
  else printf '%s\n\n[The "%s" skill is available and looks relevant. Use it if it applies.]' "$p" "$SKILL"; fi
}

run_agy() { # model, prompt   (uses DIR / WRITE)
  [ -x "$AGY" ] || die "antigravity CLI not installed"
  local model="$1" p="$2" mode=(--sandbox) marker rc=0
  # A non-interactive run has nobody to approve a shell prompt, so any command the agent reaches
  # for just kills the run. Steer it onto its file tools in BOTH modes, not only --write.
  p="Using your file read/write tools ONLY (do not run any shell/terminal commands): $p"
  if [ -n "$WRITE" ]; then
    mode=(--sandbox --mode accept-edits)
    p="$p [Write files into the workspace directory $DIR itself, not into any artifact directory.]"
    marker="$(mktemp "$TMP/wm.XXXXXX")"
  fi
  p="$(apply_skill agy "$p")"
  # --add-dir is required: without it the agent has no workspace and permission checks deny it.
  ( cd "$DIR" && "$AGY" -p "$p" "${mode[@]}" --add-dir "$DIR" --model "$model" </dev/null ) || rc=$?
  # Some models' write tool is confined to their own artifact dir, so they report "Done!" having
  # touched nothing here (observed on claude-sonnet-4-6). Verify the workspace actually changed.
  if [ -n "$WRITE" ]; then
    local changed
    changed="$(find "$DIR" -newer "$marker" -not -path '*/.git/*' -print -quit 2>/dev/null)"
    if [ -z "$changed" ]; then
      [ "$rc" -ne 0 ] && { echo "delegate: $model exited $rc and changed nothing in $DIR (see error above)" >&2; return "$rc"; }
      if [ "$model" != "$M_WRITE" ]; then
        echo "delegate: $model wrote nothing to $DIR (its write tool is confined to its artifact dir); retrying with $M_WRITE" >&2
        : > "$marker"
        ( cd "$DIR" && "$AGY" -p "$p" "${mode[@]}" --add-dir "$DIR" --model "$M_WRITE" </dev/null ) || rc=$?
        changed="$(find "$DIR" -newer "$marker" -not -path '*/.git/*' -print -quit 2>/dev/null)"
      fi
      [ -n "$changed" ] || { echo "delegate: --write changed nothing in $DIR even after retry. Use codex --write." >&2; return 1; }
    fi
  fi
  return $rc
}

tier() { # model, args...
  local model="$1"; shift
  [ $# -ge 1 ] || die "usage: delegate.sh <verb> \"<prompt>\" [dir] [--write]"
  local p="$1"; shift; parse_opts "$@"; run_agy "$model" "$p"
}

case "${1:-}" in
providers)
  # Accumulate, then emit once: piping into `head` closes the pipe mid-way and each separate echo
  # would report "write error: Broken pipe".
  po=""
  if [ -x "$AGY" ]; then po="antigravity  available (plan) hard=$M_HARD code=$M_CODE read=$M_READ cheap=$M_CHEAP write-retry=$M_WRITE"
  else po="antigravity  MISSING"; fi
  if [ -x "$CODEX" ]; then po="$po
codex        available (plan: $(jq -r .auth_mode "$HOME/.codex/auth.json" 2>/dev/null))"
  else po="$po
codex        MISSING"; fi
  orx=0
  if [ -n "$OR_KEY" ]; then
    # "key present" only proves a file exists; --check asks OpenRouter whether it actually works.
    if [ "${2:-}" = "--check" ]; then
      kr="$(curl_key "Authorization: Bearer $OR_KEY" "$OR_URL/key" </dev/null \
        | jq -r 'if .error then "KEY REJECTED: \(.error.message)" else "key valid (limit: \(.data.limit // "n/a"))" end')"
      po="$po
openrouter   $kr"
      case "$kr" in "KEY REJECTED"*) orx=1 ;; esac
    else
      po="$po
openrouter   key present (not verified; use: providers --check)"
    fi
  else po="$po
openrouter   no key"; fi
  if [ -n "$GK" ]; then po="$po
ai-studio    key present (images blocked on free tier)"
  else po="$po
ai-studio    no key"; fi
  printf '%s\n' "$po" 2>/dev/null || true
  exit "$orx"
  ;;

# --- antigravity, tiered. Match the model to the difficulty, not to the habit. ---
hard)  shift; tier "$M_HARD"  "$@" ;;   # subtle / cross-cutting
code)  shift; tier "$M_CODE"  "$@" ;;   # ordinary implementation
read)  shift; tier "$M_READ"  "$@" ;;   # read/search/summarize a tree
cheap) shift; tier "$M_CHEAP" "$@" ;;   # trivial
antigravity|agy) shift; tier "${AGY_MODEL:-$M_CODE}" "$@" ;;

codex) # delegate.sh codex "<prompt>" [dir] [--write]  -- the one that can run shell/tests
  [ -x "$CODEX" ] || die "codex not installed"
  shift; [ $# -ge 1 ] || die 'usage: delegate.sh codex "<prompt>" [dir] [--write]'
  p="$1"; shift; parse_opts "$@"; p="$(apply_skill codex "$p")"
  sb="read-only"; [ -n "$WRITE" ] && sb="workspace-write"
  out="$(mktemp "$TMP/out.XXXXXX")"
  [ -n "$WRITE" ] && wmark="$(mktemp "$TMP/cw.XXXXXX")"
  # Do not swallow stderr: when codex fails, its message is the only diagnostic there is.
  if "$CODEX" exec --sandbox "$sb" -C "$DIR" --skip-git-repo-check -o "$out" "$p" </dev/null >/dev/null; then
    cat "$out"
  else
    echo "delegate: codex exec failed (see above)" >&2; exit 1
  fi
  # Same guard as antigravity: a delegate reporting success is a claim, not evidence.
  if [ -n "$WRITE" ]; then
    ch="$(find "$DIR" -newer "$wmark" -not -path '*/.git/*' -print -quit 2>/dev/null)"
    [ -n "$ch" ] || { echo "delegate: codex --write changed nothing in $DIR" >&2; exit 1; }
  fi
  ;;
review) # delegate.sh review [dir] [--uncommitted|--base <branch>] [--by claude|codex]
  shift; rdir="$PWD"; flags=(); by=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --skill|--force-skill) die "review does not take --skill; it runs a fixed review" ;;
      --by) by="${2:?--by needs claude or codex}"; shift 2 ;;
      --base) flags+=(--base "${2:?--base needs a branch}"); shift 2 ;;
      -*) flags+=("$1"); shift ;;
      *) rdir="$1"; shift ;;
    esac
  done
  [ -d "$rdir" ] || die "not a directory: $rdir"
  [ ${#flags[@]} -gt 0 ] || flags=(--uncommitted)
  # Reviewing with the same vendor that wrote the code mostly confirms it, so default to the other
  # one: inside Codex review with Claude, otherwise review with Codex.
  [ -n "$by" ] || { [ "$(host_agent)" = codex ] && by=claude || by=codex; }
  case "$by" in
  codex)
    [ -x "$CODEX" ] || die "codex not installed (try --by claude)"
    ( cd "$rdir" && "$CODEX" review "${flags[@]}" </dev/null )
    ;;
  claude)
    [ -x "$AGY" ] || die "antigravity not installed, so no Claude reviewer is available"
    # Antigravity cannot run shell here, so hand it the diff rather than expecting it to fetch one.
    case "${flags[*]}" in
      *--base*) base="${flags[1]}"; d="$(git -C "$rdir" diff "$base"...HEAD 2>/dev/null)" ;;
      *) d="$(git -C "$rdir" diff HEAD 2>/dev/null; git -C "$rdir" ls-files --others --exclude-standard 2>/dev/null | sed 's/^/UNTRACKED: /')" ;;
    esac
    [ -n "$d" ] || { echo "no changes to review"; exit 0; }
    [ "${#d}" -le 200000 ] || die "diff is too large to review in one prompt (${#d} bytes)"
    DIR="$rdir"; WRITE=""; SKILL=""
    run_agy "$M_HARD" "You are an adversarial code reviewer. Find real defects in this diff:
correctness bugs, security issues, missing error handling, broken edge cases. Be specific about
file and line. Say plainly if you find nothing wrong -- do not invent problems.

$d"
    ;;
  *) die "--by must be claude or codex" ;;
  esac
  ;;
or) # delegate.sh or "<prompt>" [model] [--skill NAME] -- a pinned model does not fall back
  shift; [ $# -ge 1 ] || die 'usage: delegate.sh or "<prompt>" [model] [--skill NAME]'
  op="$1"; om=""; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --skill|--force-skill) SKILL="${2:?needs a skill name}"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) om="$1"; shift ;;
    esac
  done
  # A raw chat completion has no skill system, so the only way to apply one is to paste it in.
  if [ -n "$SKILL" ]; then
    sf="$HOME/.claude/skills/$SKILL/SKILL.md"
    [ -f "$sf" ] || die "skill '$SKILL' not found at $sf (openrouter has no skills of its own)"
    [ "$(wc -c < "$sf")" -le 20000 ] || die "skill '$SKILL' is too large to inline into a prompt"
    op="$(printf 'Follow these instructions:\n\n%s\n\n---\n\n%s' "$(cat "$sf")" "$op")"
  fi
  if [ -n "$om" ]; then or_chat "$om" "$op"; else or_free "$op"; fi
  ;;
skills) # delegate.sh skills [agy|codex]
  case "${2:-}" in
    agy|codex) list_skills "$2" ;;
    "") echo "--- agy:"; list_skills agy; echo "--- codex:"; list_skills codex ;;
    *) die "usage: delegate.sh skills [agy|codex]" ;;
  esac
  ;;
or-models) free_models ;;

image) # delegate.sh image "<prompt>" out.png [--paid]
  shift; [ $# -ge 2 ] || die 'usage: delegate.sh image "<prompt>" out.png [--paid]'
  prompt="$1"; out="$2"; shift 2; paid=""
  for a in "$@"; do [ "$a" = "--paid" ] && paid=1; done
  mkdir -p "$(dirname "$out")" || die "cannot create output directory for $out"
  dest_dir="$(cd "$(dirname "$out")" && pwd)"; out="$dest_dir/$(basename "$out")"; b64=""
  if [ -x "$AGY" ]; then
    brain="$HOME/.gemini/antigravity-cli/brain"; marker="$(mktemp "$TMP/im.XXXXXX")"
    ( cd "$dest_dir" && "$AGY" -p "Use your generate_image tool to create: $prompt" \
        --sandbox --add-dir "$dest_dir" --model "$M_CHEAP" </dev/null ) >/dev/null 2>&1 || true
    # The tool writes into its own artifact dir and names the path only in prose. Take the NEWEST
    # image it produced since the marker -- directory order is not creation order.
    src=""; newest=0
    if [ -d "$brain" ]; then
      while IFS= read -r -d '' f; do
        t="$(mtime_name "$f" | cut -d' ' -f1)"
        if [ "${t:-0}" -gt "$newest" ]; then newest="$t"; src="$f"; fi
      done < <(find "$brain" -type f -newer "$marker" \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) -print0 2>/dev/null)
    fi
    if [ -n "$src" ] && [ -f "$src" ]; then
      case "$out" in
        *.png) if ! to_png "$src" "$out"; then
                 out="${out%.png}.${src##*.}"; cp "$src" "$out"
                 echo "[delegate] png conversion failed; wrote original format instead" >&2
               fi ;;
        *) cp "$src" "$out" ;;
      esac
      echo "wrote $out (antigravity, free)"; exit 0
    fi
    echo "[delegate] antigravity produced no image, trying codex imagegen" >&2
  fi
  # Second free path: codex's built-in image_gen tool needs no API key, so it rides the plan too.
  if [ -x "$CODEX" ]; then
    cmark="$(mktemp "$TMP/cm.XXXXXX")"
    ( cd "$dest_dir" && "$CODEX" exec --sandbox workspace-write -C "$dest_dir" --skip-git-repo-check \
        "/imagegen Generate: $prompt. Save the final image to $out" </dev/null ) >/dev/null 2>&1 || true
    if [ -f "$out" ] && [ "$out" -nt "$cmark" ] && file -b "$out" | grep -qiE 'image|bitmap'; then
      echo "wrote $out (codex imagegen, free)"; exit 0
    fi
    echo "[delegate] codex imagegen produced no image" >&2
  fi
  # Everything below this line costs money, so it is opt-in rather than a silent fallback.
  [ -n "$paid" ] || die "both free image paths failed. Paid providers need explicit --paid (OpenRouter spends real credit)."
  if [ -n "$GK" ]; then
    resp="$(jq -n --arg p "$prompt" '{contents:[{parts:[{text:$p}]}]}' \
      | curl_key "x-goog-api-key: $GK" "$G_URL/gemini-2.5-flash-image:generateContent" \
          -H 'Content-Type: application/json' -d @-)"
    b64="$(printf '%s' "$resp" | jq -r '(.candidates[0].content.parts[]?|select(.inlineData).inlineData.data) // empty' | head -1)"
    [ -n "$b64" ] || echo "[delegate] AI Studio: $(printf '%s' "$resp" | jq -r '.error.message // "no image in response"' | head -1 | cut -c1-120) -- trying OpenRouter (paid)" >&2
  fi
  if [ -z "$b64" ]; then
    [ -n "$OR_KEY" ] || die "no image provider available"
    b64="$(jq -n --arg m "google/gemini-2.5-flash-image" --arg p "$prompt" \
        '{model:$m,messages:[{role:"user",content:$p}],modalities:["image","text"]}' \
      | curl_key "Authorization: Bearer $OR_KEY" "$OR_URL/chat/completions" \
          -H 'Content-Type: application/json' -d @- \
      | jq -r 'if .error then "ERROR: \(.error.message)"|halt_error(1)
               else (.choices[0].message.images[0].image_url.url // empty) end' \
      | sed 's|^data:image/[a-z]*;base64,||')"
  fi
  # jq prints a literal "null" for a missing field, which base64-decodes into a 3-byte file that
  # every later step happily treats as an image. Refuse it instead of reporting success.
  case "$b64" in ""|null) die "provider returned no image data" ;; esac
  printf '%s' "$b64" | b64d > "$out"
  file -b "$out" | grep -qiE 'image|bitmap' || { rm -f "$out"; die "decoded output is not an image"; }
  echo "wrote $out (paid)"
  ;;
*) die "usage: delegate.sh providers|hard|code|read|cheap|codex|review|or|or-models|image|skills ...
       verbs take [dir] [--write] [--skill NAME | --force-skill NAME]" ;;
esac
