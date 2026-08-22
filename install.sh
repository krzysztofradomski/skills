#!/usr/bin/env bash
# Install agent skills for Claude Code (and Codex CLI, if present).
#   bash install.sh                # install every skill
#   bash install.sh delegate       # install just one
# Env: SKILLS_DIR (clone location), CLAUDE_DIR, CODEX_DIR, BIN_DIR.
set -euo pipefail

REPO="${SKILLS_REPO:-https://github.com/krzysztofradomski/skills.git}"
DEST="${SKILLS_DIR:-$HOME/.local/share/agent-skills}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude/skills}"
CODEX_DIR="${CODEX_DIR:-$HOME/.codex/skills}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

say() { printf '%s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }
command -v git >/dev/null || die "git is required"

# Clone, or update a clone that is already there.
if [ -d "$DEST/.git" ]; then
  say "==> updating $DEST"; git -C "$DEST" pull --ff-only -q || die "could not fast-forward $DEST; pull it by hand"
else
  [ -e "$DEST" ] && die "$DEST exists and is not a git clone; move it or set SKILLS_DIR"
  say "==> cloning into $DEST"; mkdir -p "$(dirname "$DEST")"; git clone -q "$REPO" "$DEST"
fi

# A skill is any directory holding a SKILL.md.
available() { for d in "$DEST"/*/; do [ -f "$d/SKILL.md" ] && basename "$d"; done; }
wanted=("$@"); [ ${#wanted[@]} -gt 0 ] || IFS=$'\n' read -r -d '' -a wanted < <(available && printf '\0')

# Never clobber a real directory: only replace a symlink we already own.
link() { # target, linkname
  if [ -L "$2" ]; then
    [ "$(readlink "$2")" = "$1" ] && { say "    = $2 (already linked)"; return; }
    rm -f "$2"
  elif [ -e "$2" ]; then
    say "    ! $2 exists and is not a symlink -- skipped (move it, then re-run)"; return
  fi
  ln -s "$1" "$2"; say "    + $2"
}

for s in "${wanted[@]}"; do
  [ -f "$DEST/$s/SKILL.md" ] || die "no such skill: $s (available: $(available | tr '\n' ' '))"
  say "==> $s"
  mkdir -p "$CLAUDE_DIR"; link "$DEST/$s" "$CLAUDE_DIR/$s"          # Claude Code: the primary target
  [ -d "$(dirname "$CODEX_DIR")" ] && { mkdir -p "$CODEX_DIR"; link "$DEST/$s" "$CODEX_DIR/$s"; }
  if [ -d "$DEST/$s/scripts" ]; then
    mkdir -p "$BIN_DIR"
    for f in "$DEST/$s/scripts"/*; do [ -x "$f" ] && link "$f" "$BIN_DIR/$(basename "$f")"; done
  fi
done

say ""
say "Installed to $DEST. Start a NEW agent session -- skills load at startup."
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) say "Add to your shell profile:  export PATH=\"$BIN_DIR:\$PATH\"" ;; esac
say "Read $DEST/<skill>/README.md for that skill's requirements."
