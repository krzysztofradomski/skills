#!/usr/bin/env bash
# Make a small looping (or still) SVG icon: ask a delegate for the SVG source,
# then sanitize, resize and re-time it locally. See the svg skill's SKILL.md.
set -euo pipefail

# Normally reached through a symlink on PATH, so resolve the chain to find
# svgpack.py next to the real file. macOS has no `readlink -f`.
self="${BASH_SOURCE[0]}"
while [ -L "$self" ]; do
  target="$(readlink "$self")"
  case "$target" in /*) self="$target" ;; *) self="$(dirname "$self")/$target" ;; esac
done
HERE="$(cd "$(dirname "$self")" && pwd)"
PACK="$HERE/svgpack.py"
PY="${PYTHON:-python3}"
DELEGATE="$(command -v delegate.sh || echo "$HOME/.local/bin/delegate.sh")"

die() { echo "svg: $*" >&2; exit 2; }
[ -f "$PACK" ] || die "cannot find svgpack.py next to $self"
command -v "$PY" >/dev/null || die "python3 is required (or set \$PYTHON)"
pack() { "$PY" "$PACK" "$@"; }

# Defaults.
size=32; duration=1; loop=0; still=""; bg=""; tier="code"; style=""
keep=""; retries=1; round=2; title=""; allow_raster=""

need_num() { case "$2" in ''|*[!0-9.]*) die "$1 needs a number, got '${2:-}'" ;; esac; }

parse_opts() {
  REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --size)     need_num --size "${2:-}"; size="$2"; shift 2 ;;
      --duration) need_num --duration "${2:-}"; duration="$2"; shift 2 ;;
      --loop)     need_num --loop "${2:-}"; loop="$2"; shift 2 ;;
      --retries)  need_num --retries "${2:-}"; retries="$2"; shift 2 ;;
      --round)    round="${2:-}"; [ -n "$round" ] || die "--round needs a number (-1 to disable)"; shift 2 ;;
      --still)    still=1; shift ;;
      --bg)       bg="${2:-}"; [ -n "$bg" ] || die "--bg needs a color"; shift 2 ;;
      --opaque)   bg="#ffffff"; shift ;;
      --tier)     tier="${2:-}"
                  case "$tier" in cheap|read|code|hard|or|codex) ;;
                    *) die "--tier must be cheap|read|code|hard|or|codex (got '${tier:-}')" ;; esac
                  shift 2 ;;
      --style)    style="${2:-}"; [ -n "$style" ] || die "--style needs a description"; shift 2 ;;
      --title)    title="${2:-}"; [ -n "$title" ] || die "--title needs text"; shift 2 ;;
      --keep-raw) keep="${2:-}"; [ -n "$keep" ] || die "--keep-raw needs a file path"; shift 2 ;;
      --allow-raster) allow_raster="--allow-raster"; shift ;;
      --) shift; REST+=("$@"); break ;;
      -)  REST+=("-"); shift ;;      # stdin, not a flag
      -*) die "unknown option $1" ;;
      *) REST+=("$1"); shift ;;
    esac
  done
}

pack_opts=()
build_opts() {
  pack_opts=(--size "$size" --duration "$duration" --loop "$loop" --round "$round")
  [ -n "$still" ] && pack_opts+=(--still)
  [ -n "$bg" ] && pack_opts+=(--bg "$bg")
  [ -n "$title" ] && pack_opts+=(--title "$title")
  [ -n "$allow_raster" ] && pack_opts+=("$allow_raster")
  return 0            # a false last test would otherwise abort the script under set -e
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
trap 'rm -rf "$TMP"; exit 130' INT
trap 'rm -rf "$TMP"; exit 143' TERM

# An SVG is code, so this goes to a text tier, not to an image model: it costs
# plan allowance rather than the small daily image quota, and the result is
# reviewable, diffable and re-editable instead of being a bag of pixels.
prompt_for() { # subject
  local anim bgline
  if [ -n "$bg" ]; then
    bgline="The background is one full-canvas rect filled $bg, drawn first."
  else
    bgline="No background rect: the artwork sits on transparency, so nothing may fill the whole canvas."
  fi
  if [ -n "$still" ]; then
    anim="This is a STILL image: no animation at all. Do not include <animate>,
  <animateTransform>, <set>, CSS animations, transitions or @keyframes."
  else
    anim="Animate it with SMIL elements (<animate>, <animateTransform>) -- not CSS
  animations. One loop lasts exactly ${duration}s: every animation's dur must add up to
  that one cycle, and each carries repeatCount=\"indefinite\". The loop is seamless:
  the last value of every animation equals its first."
  fi
  cat <<EOF
Write one complete SVG icon and output NOTHING but its source. No explanation
before or after, no markdown fence, no comments.

Subject: $1

Requirements:
- A single <svg> root with xmlns="http://www.w3.org/2000/svg" and viewBox="0 0 100 100".
  Draw in that 100x100 coordinate space; it will be rendered at ${size}x${size} pixels.
- ${style:-Simple flat vector style that stays readable at ${size}x${size}: a strong silhouette, few
  shapes, few flat colors, generous stroke widths, no fine detail, no gradients unless
  they are essential, no blur filters.}
- $anim
- $bgline
- Vector shapes only. No <image>, no embedded raster or base64 data, no external
  references, no <script>, no event handlers, no <foreignObject>, no web fonts.
  Text, if any, must be converted to paths or drawn with shapes.
- Keep it small: under 4KB of source.
EOF
}

generate() { # subject, attempt-tier, extra-instruction -> writes $TMP/raw.txt
  [ -x "$DELEGATE" ] || die "delegate.sh not found on PATH -- install the delegate skill first
      (https://github.com/krzysztofradomski/skills), or write the SVG yourself and use 'svg.sh build'"
  local p; p="$(prompt_for "$1")"
  [ -n "${3:-}" ] && p="$p

Your previous attempt was rejected: $3
Fix exactly that and output the corrected SVG source only."
  echo "[svg] asking delegate ($2) for the source" >&2
  "$DELEGATE" "$2" "$p" > "$TMP/raw.txt" || return 1
  [ -s "$TMP/raw.txt" ] || return 1
  return 0
}

keep_raw() { [ -n "$keep" ] && [ -f "$TMP/raw.txt" ] && { cp "$TMP/raw.txt" "$keep"
             echo "[svg] raw reply kept in $keep" >&2; }; return 0; }

make_svg() { # subject, out
  local subject="$1" out="$2" attempt=0 t="$tier" err="" rc=0
  build_opts
  while :; do
    if generate "$subject" "$t" "$err"; then
      err="$(pack build "$out" "$TMP/raw.txt" "${pack_opts[@]}" 2>&1 >"$TMP/ok.txt")" && rc=0 || rc=$?
      cat "$TMP/ok.txt"
      [ -n "$err" ] && printf '%s\n' "$err" >&2
      if [ "$rc" -eq 0 ]; then keep_raw; pack probe "$out"; return 0; fi
    else
      err="the delegate call itself failed"
      echo "[svg] $err" >&2
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -le "$retries" ] || break
    # Rerunning a tier up costs plan allowance, not your context, so a confused
    # result is worth re-asking rather than hand-patching.
    case "$t" in cheap|read) t="code" ;; code) t="hard" ;; esac
    echo "[svg] retry $attempt/$retries on tier '$t'" >&2
  done
  keep_raw
  die "could not get a usable SVG after $((attempt)) attempt(s). Last error above;$([ -n "$keep" ] && echo " raw reply in $keep;") try --tier hard, or --still if the subject does not animate well."
}

case "${1:-}" in
make) # svg.sh make "<subject>" out.svg [opts]
  shift; parse_opts "$@"; set -- "${REST[@]+"${REST[@]}"}"
  [ $# -ge 2 ] || die 'usage: svg.sh make "<subject>" out.svg [opts]'
  make_svg "$1" "$2"
  ;;
still) # svg.sh still "<subject>" out.svg [opts]   -- same as make --still
  shift; still=1; parse_opts "$@"; set -- "${REST[@]+"${REST[@]}"}"
  [ $# -ge 2 ] || die 'usage: svg.sh still "<subject>" out.svg [opts]'
  still=1; make_svg "$1" "$2"
  ;;
build) # svg.sh build out.svg <raw-reply-or-svg|-> [opts]
  shift; parse_opts "$@"; set -- "${REST[@]+"${REST[@]}"}"
  [ $# -ge 2 ] || die 'usage: svg.sh build out.svg <file|-> [opts]'
  build_opts
  pack build "$1" "$2" "${pack_opts[@]}"
  pack probe "$1"
  ;;
probe) shift; [ $# -ge 1 ] || die "usage: svg.sh probe <file.svg>"; pack probe "$1" ;;
preview) # svg.sh preview <file.svg> out.png [--width N]
  shift; w=512
  args=(); while [ $# -gt 0 ]; do
    case "$1" in --width) need_num --width "${2:-}"; w="$2"; shift 2 ;; *) args+=("$1"); shift ;; esac
  done
  set -- "${args[@]+"${args[@]}"}"
  [ $# -ge 2 ] || die "usage: svg.sh preview <file.svg> out.png [--width N]"
  [ -f "$1" ] || die "no such file: $1"
  src="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; out="$2"
  # SVG is a picture only once something rasterizes it; take whichever of these
  # the machine actually has. A still frame of frame 0 is enough to see that the
  # art is right -- the animation you check in a browser.
  if command -v rsvg-convert >/dev/null; then rsvg-convert -w "$w" -h "$w" "$src" -o "$out"
  elif command -v magick >/dev/null; then magick -background none -density 384 "$src" -resize "${w}x${w}" "$out"
  elif command -v convert >/dev/null; then convert -background none -density 384 "$src" -resize "${w}x${w}" "$out"
  elif command -v inkscape >/dev/null; then inkscape "$src" -w "$w" -h "$w" -o "$out" >/dev/null 2>&1
  else
    ch="${CHROME:-$(command -v chromium || command -v chromium-browser || command -v google-chrome \
          || command -v chrome || echo "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")}"
    [ -x "$ch" ] || die "no rasterizer found. Install librsvg (rsvg-convert), ImageMagick or Inkscape,
      or just open the SVG in a browser -- that is the only renderer that also plays the animation."
    # Chrome renders the file at its intrinsic size in the corner of the window,
    # so go through a page that stretches it to fill the shot instead.
    printf '<body style="margin:0"><img src="file://%s" style="width:100vw;height:100vh"></body>' \
      "$src" > "$TMP/preview.html"
    # $CHROME_FLAGS is the escape hatch for odd environments (a container running
    # as root needs --no-sandbox, which is not something to turn on by default).
    ( cd "$(dirname "$out")" && "$ch" --headless --disable-gpu --hide-scrollbars \
        --default-background-color=00000000 ${CHROME_FLAGS:-} \
        --screenshot="$(basename "$out")" --window-size="$w,$w" "file://$TMP/preview.html" ) >/dev/null 2>&1
    echo "[svg] rendered with headless Chrome (frame 0 only; the animation plays in a browser)" >&2
  fi
  [ -f "$out" ] || die "rasterizing produced nothing"
  echo "wrote $out (${w}px, frame 0)"
  ;;
check)
  printf 'python3      %s\n' "$(command -v "$PY" || echo MISSING)"
  printf 'svgpack.py   %s\n' "$PACK"
  if [ -x "$DELEGATE" ]; then printf 'delegate.sh  %s\n' "$DELEGATE"
  else printf 'delegate.sh  MISSING  (generation needs it; build/probe/preview do not)\n'; fi
  r="$(command -v rsvg-convert || command -v magick || command -v convert || command -v inkscape || true)"
  printf 'rasterizer   %s\n' "${r:-none found (preview will try headless Chrome)}"
  ;;
*) die 'usage: svg.sh make "<subject>" out.svg | still "<subject>" out.svg | build out.svg <file|->
              | probe <f.svg> | preview <f.svg> out.png | check
       opts: --still  --size 16|32|64|128 (32)  --duration SEC (1, max 3)  --loop N (0=forever)
             --bg COLOR | --opaque  --tier cheap|read|code|hard|or|codex (code)  --style "..."
             --title TEXT  --keep-raw FILE  --retries N (1)  --round N (2)  --allow-raster' ;;
esac
