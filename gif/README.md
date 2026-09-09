# gif

Small looping animated GIFs, for Claude Code (primary) and Codex CLI. Square, 16/32/64/128 px,
transparent or on a solid background, up to 3 seconds — the sizes an icon, sprite, loader or
chat emoji actually ships at.

It builds on [`delegate`](../delegate/): frames are generated with `delegate.sh image`, which runs on
Antigravity or Codex **plan allowance**, so a normal run costs nothing on top of your subscription.
Assembly happens locally, with no network and no ImageMagick.

## Requirements

- `python3` with [Pillow](https://pypi.org/project/pillow/) (`pip install pillow`)
- The [`delegate`](../delegate/) skill on your `PATH` — only to *generate* frames. Assembling frames
  or sprite sheets you already have needs nothing but Pillow.
- `bash`. Written for bash 3.2 (macOS) as well as newer bash.

Check with `gif.sh check`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/krzysztofradomski/skills/main/install.sh | bash -s delegate gif
```

Or by hand, from the root of your clone of
[the skills repo](https://github.com/krzysztofradomski/skills):

```bash
ln -s "$PWD/gif" ~/.claude/skills/gif                  # Claude Code
ln -s "$PWD/gif" ~/.codex/skills/gif                   # optional: Codex CLI
ln -s "$PWD/gif/scripts/gif.sh" ~/.local/bin/          # both, plus your own shell
```

Only `gif.sh` goes on your `PATH`; `gifpack.py` sits next to it and is found through the symlink.

## Use

```bash
gif.sh make "a coin spinning end over end" coin.gif          # 32x32, transparent, 1s, forever
gif.sh make "a bouncing ball" ball.gif --size 64 --duration 2 --frames 12
gif.sh make "a loading spinner" spin.gif --bg '#111827'      # opaque
gif.sh frames out.gif ./frames --size 128 --matte none       # your own frames
gif.sh sheet sprites.png out.gif --cols 6                    # your own sprite sheet
gif.sh probe out.gif
```

Or just ask your agent for "a 64px transparent looping gif of a spinning coin" and let it load the
skill.

## Limitations

- **Frame quality is the image model's**, not this skill's. At 16–32px you want flat shapes and a
  strong silhouette; ornate subjects turn to noise however good the downscaler is.
- **Sheet cutting can misalign.** The model is asked for N equal frames in one row and usually
  obliges, but not always. `--keep-frames` keeps the sheet so you can re-cut it with `gif.sh sheet`
  instead of spending quota on a regeneration.
- **Image generation has a finite daily quota** on plan allowance. When it is spent, `delegate`
  says so and `gif.sh` stops; paid providers stay behind `--paid`.
- GIF gives you 1-bit alpha and 10ms delay steps. Both are handled here, neither can be avoided —
  soft shadows against a page background are not achievable in this format.
- Developed on Linux; the script avoids GNU-only flags and `readlink -f` so it works on macOS bash
  3.2, but macOS is less exercised.

Full behaviour and flags: [SKILL.md](SKILL.md) and [REFERENCE.md](REFERENCE.md).

MIT, like the rest of the repo.
