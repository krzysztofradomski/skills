#!/usr/bin/env bash
# Make a small looping GIF: generate frames through delegate.sh (plan allowance,
# free), then assemble them locally with Pillow. See the gif skill's SKILL.md.
set -euo pipefail

# The script is normally reached through a symlink on PATH, so resolve the link
# chain to find gifpack.py next to the real file. macOS has no `readlink -f`.
self="${BASH_SOURCE[0]}"
while [ -L "$self" ]; do
  target="$(readlink "$self")"
  case "$target" in /*) self="$target" ;; *) self="$(dirname "$self")/$target" ;; esac
done
HERE="$(cd "$(dirname "$self")" && pwd)"
PACK="$HERE/gifpack.py"
PY="${PYTHON:-python3}"
DELEGATE="$(command -v delegate.sh || echo "$HOME/.local/bin/delegate.sh")"

die() { echo "gif: $*" >&2; exit 2; }
[ -f "$PACK" ] || die "cannot find gifpack.py next to $self"
command -v "$PY" >/dev/null || die "python3 is required (or set \$PYTHON)"
pack() { "$PY" "$PACK" "$@"; }

MATTE="#FF00FF"   # flat backdrop we ask the model for, and key out afterwards

# Defaults, all overridable per run.
size=32; frames=8; duration=1; loop=0; colors=64; opaque=""; bg=""
fuzz=18; trim=""; filt="auto"; keep=""; per_frame=""; paid=""; style=""; frames_set=""
pack_extra=()

need_num() { case "$2" in ''|*[!0-9.]*) die "$1 needs a number, got '${2:-}'" ;; esac; }

parse_opts() { # consumes the flags common to every verb
  REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --size)      need_num --size "${2:-}"; size="$2"; shift 2 ;;
      --frames)    need_num --frames "${2:-}"; frames="$2"; frames_set=1; shift 2 ;;
      --duration)  need_num --duration "${2:-}"; duration="$2"; shift 2 ;;
      --loop)      need_num --loop "${2:-}"; loop="$2"; shift 2 ;;
      --colors)    need_num --colors "${2:-}"; colors="$2"; shift 2 ;;
      --fuzz)      need_num --fuzz "${2:-}"; fuzz="$2"; shift 2 ;;
      --opaque)    opaque=1; shift ;;
      --bg)        opaque=1; bg="${2:-}"; [ -n "$bg" ] || die "--bg needs a color"; shift 2 ;;
      --matte)     MATTE="${2:-}"; [ -n "$MATTE" ] || die "--matte needs a color or 'none'"; shift 2 ;;
      --no-trim)   trim="--no-trim"; shift ;;
      --filter)    filt="${2:-}"; [ -n "$filt" ] || die "--filter needs auto|box|lanczos|nearest"; shift 2 ;;
      --keep-frames) keep="${2:-}"; [ -n "$keep" ] || die "--keep-frames needs a directory"; shift 2 ;;
      --style)     style="${2:-}"; [ -n "$style" ] || die "--style needs a description"; shift 2 ;;
      --per-frame) per_frame=1; shift ;;
      --paid)      paid="--paid"; shift ;;
      --) shift; REST+=("$@"); break ;;
      -*) die "unknown option $1" ;;
      *) REST+=("$1"); shift ;;
    esac
  done
}

build_opts() {
  pack_extra=(--size "$size" --duration "$duration" --loop "$loop" --colors "$colors"
              --matte "$MATTE" --fuzz "$fuzz" --filter "$filt")
  [ -n "$opaque" ] && pack_extra+=(--opaque)
  [ -n "$bg" ] && pack_extra+=(--bg "$bg")
  [ -n "$trim" ] && pack_extra+=("$trim")
  return 0            # a false last test would otherwise abort the script under set -e
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
trap 'rm -rf "$TMP"; exit 130' INT
trap 'rm -rf "$TMP"; exit 143' TERM

# The frames are generated as ONE sprite sheet rather than N separate images:
# one image call instead of N (image quota is small and daily), and the model
# sees every frame at once, which is the only thing that keeps the subject from
# redrawing itself between frames.
sheet_prompt() { # subject
  cat <<EOF
A horizontal sprite sheet for a looping animation. Exactly $frames frames in ONE
single row, left to right, all the same square size, edge to edge with no gaps,
no grid lines, no borders, no frame numbers, no text, no drop shadows and no
padding around the row.

Subject of the animation: $1

The animation must loop seamlessly: the last frame flows back into the first.
${style:-Simple bold pixel-art style that stays readable when each frame is scaled down to ${size}x${size} pixels: few flat colors, thick chunky shapes, strong silhouette, no fine detail, no gradients, no anti-aliased glow.}
The subject fills each frame and is centred in it, at the same scale in every frame.

The background of every frame is pure flat $MATTE and absolutely nothing else:
no shading, no texture, no vignette, no gradient on the background.
EOF
}

frame_prompt() { # subject, index, total
  cat <<EOF
Frame $2 of $3 of a seamless looping animation, drawn as a single square image.

Subject of the animation: $1

${style:-Simple bold pixel-art style that stays readable when scaled down to ${size}x${size} pixels: few flat colors, thick chunky shapes, strong silhouette, no fine detail, no gradients.}
Keep the subject at the exact same position, scale and style as the other frames;
only the animated motion differs. The background is pure flat $MATTE and nothing else.
EOF
}

generate() { # subject -> prints frame paths, one per line, into $TMP/frames
  [ -x "$DELEGATE" ] || die "delegate.sh not found on PATH -- install the delegate skill first
      (https://github.com/krzysztofradomski/skills), or generate frames yourself and use 'gif.sh frames'"
  # Pillow does every pixel of the assembly, so check for it before an image call is spent
  # generating frames nothing can turn into a GIF.
  "$PY" -c 'import PIL' 2>/dev/null || die "Pillow is required -- pip install pillow, or brew install pillow on Homebrew python"
  mkdir -p "$TMP/frames"
  if [ -n "$per_frame" ]; then
    local i=1
    while [ "$i" -le "$frames" ]; do
      echo "[gif] frame $i/$frames" >&2
      "$DELEGATE" image "$(frame_prompt "$1" "$i" "$frames")" "$TMP/frames/frame_$(printf '%02d' "$i").png" $paid >&2 \
        || die "delegate could not generate frame $i"
      i=$((i + 1))
    done
  else
    echo "[gif] generating a sprite sheet of $frames frames" >&2
    "$DELEGATE" image "$(sheet_prompt "$1")" "$TMP/sheet.png" $paid >&2 \
      || die "delegate could not generate the sprite sheet (image quota is finite; try again later, or --paid)"
    [ -f "$TMP/sheet.png" ] || die "delegate reported success but wrote no sheet"
    pack slice "$TMP/sheet.png" "$TMP/frames" --cols "$frames" >/dev/null
  fi
  ls "$TMP/frames"/*.png
}

keep_frames() {
  [ -n "$keep" ] || return 0
  mkdir -p "$keep"
  cp "$TMP/frames"/*.png "$keep"/ 2>/dev/null || true
  [ -f "$TMP/sheet.png" ] && cp "$TMP/sheet.png" "$keep"/
  echo "[gif] frames kept in $keep" >&2
  return 0
}

case "${1:-}" in
make) # gif.sh make "<subject>" out.gif [opts]
  shift; parse_opts "$@"; set -- "${REST[@]+"${REST[@]}"}"
  [ $# -ge 2 ] || die 'usage: gif.sh make "<subject>" out.gif [opts]'
  subject="$1"; out="$2"
  generate "$subject" >/dev/null
  build_opts
  pack build "$out" "$TMP/frames"/*.png "${pack_extra[@]}" || { keep_frames; exit 1; }
  keep_frames
  pack probe "$out"
  ;;
frames) # gif.sh frames out.gif <dir|frame.png...> [opts]
  shift; parse_opts "$@"; set -- "${REST[@]+"${REST[@]}"}"
  [ $# -ge 2 ] || die 'usage: gif.sh frames out.gif <dir|frame.png ...> [opts]'
  out="$1"; shift
  src=()
  for f in "$@"; do
    if [ -d "$f" ]; then
      while IFS= read -r p; do src+=("$p"); done < <(find "$f" -maxdepth 1 -type f \
        \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) | sort)
    else
      [ -f "$f" ] || die "no such frame: $f"; src+=("$f")
    fi
  done
  [ ${#src[@]} -gt 0 ] || die "no frames found"
  build_opts
  pack build "$out" "${src[@]}" "${pack_extra[@]}"
  pack probe "$out"
  ;;
sheet) # gif.sh sheet <sheet.png> out.gif [--cols N] [--rows N] [opts]
  shift; cols=""; rows=1
  args=(); while [ $# -gt 0 ]; do
    case "$1" in
      --cols) need_num --cols "${2:-}"; cols="$2"; shift 2 ;;
      --rows) need_num --rows "${2:-}"; rows="$2"; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  parse_opts "${args[@]+"${args[@]}"}"; set -- "${REST[@]+"${REST[@]}"}"
  [ $# -ge 2 ] || die 'usage: gif.sh sheet <sheet.png> out.gif [--cols N] [--rows N] [opts]'
  [ -f "$1" ] || die "no such sheet: $1"
  [ -n "$cols" ] || cols="$frames"
  # --cols alone tells us the frame count; only an explicit --frames overrides it.
  [ -n "$frames_set" ] || frames=$((cols * rows))
  mkdir -p "$TMP/frames"
  pack slice "$1" "$TMP/frames" --cols "$cols" --rows "$rows" --count "$frames" >/dev/null
  build_opts
  pack build "$2" "$TMP/frames"/*.png "${pack_extra[@]}" || { keep_frames; exit 1; }
  keep_frames
  pack probe "$2"
  ;;
probe) shift; [ $# -ge 1 ] || die "usage: gif.sh probe <file.gif>"; pack probe "$1" ;;
check)
  printf 'python3      %s\n' "$(command -v "$PY" || echo MISSING)"
  if "$PY" -c 'import PIL; print(PIL.__version__)' >/dev/null 2>&1; then
    printf 'pillow       %s\n' "$("$PY" -c 'import PIL; print(PIL.__version__)')"
  else
    printf 'pillow       MISSING  (pip install pillow, or brew install pillow on Homebrew python)\n'
  fi
  printf 'gifpack.py   %s\n' "$PACK"
  if [ -x "$DELEGATE" ]; then printf 'delegate.sh  %s\n' "$DELEGATE"
  else printf 'delegate.sh  MISSING  (frame generation needs it; assembling your own frames does not)\n'; fi
  ;;
*) die 'usage: gif.sh make "<subject>" out.gif | frames out.gif <dir|png...> | sheet <sheet.png> out.gif | probe <f.gif> | check
       opts: --size 16|32|64|128 (32)  --frames N (8)  --duration SEC (1, max 3)  --loop N (0=forever)
             --opaque | --bg COLOR  --colors N (64)  --matte COLOR|none  --fuzz PCT (18)
             --no-trim  --filter auto|box|lanczos|nearest  --keep-frames DIR  --style "..."
             --per-frame  --paid' ;;
esac
