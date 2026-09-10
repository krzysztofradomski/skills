---
name: gif
description: Make small looping animated GIFs - square 16x16, 32x32, 64x64 or 128x128, transparent or on a solid background, up to 3 seconds. Generates the frames through the delegate skill on plan allowance (free) and assembles them locally, or assembles frames and sprite sheets you already have. Use when the user asks for a GIF, an animated icon, sprite, loader, spinner, emoji, favicon, pixel-art animation, or wants stills turned into a looping animation.
---

# GIF

Two steps, and only the first one costs anything: **generate frames** with `delegate.sh image`
(Antigravity or Codex plan allowance, free), then **assemble them locally** with `gif.sh`, which owns
everything the GIF format constrains — 1-bit alpha, 10ms delay quantum, one shared palette, frame
disposal.

## Quick start

```bash
gif.sh make "a coin spinning end over end" coin.gif        # 32x32, transparent, 1s, loops forever
gif.sh make "a bouncing ball" ball.gif --size 64 --duration 2 --frames 12
gif.sh make "a loading spinner" spin.gif --bg '#111827'    # opaque instead of transparent
gif.sh frames out.gif ./my-frames --size 128               # frames you already have (dir or files)
gif.sh sheet sprites.png out.gif --cols 6                  # slice an existing sprite sheet
gif.sh probe out.gif                                       # what the file actually contains
gif.sh check                                               # dependencies
```

**Defaults: 32x32, transparent, 1.0s, 8 frames, loops forever.** Sizes are restricted to
16 / 32 / 64 / 128 and duration to 3s; both fail loudly rather than silently rounding.

| Flag | Default | |
|---|---|---|
| `--size 16\|32\|64\|128` | 32 | square, no other sizes |
| `--frames N` | 8 | one image call either way — they come from one sprite sheet |
| `--duration SEC` | 1 | max 3 |
| `--loop N` | 0 | 0 = forever, N = that many times |
| `--opaque` / `--bg COLOR` | transparent | `--bg` implies opaque |
| `--colors N` | 64 | palette size, 2–256 |
| `--style "..."` | pixel art | replaces the style sentence in the prompt |
| `--keep-frames DIR` | — | keep the sheet and cut frames to inspect or re-cut |
| `--matte COLOR\|none`, `--fuzz PCT` | `#FF00FF`, 18 | backdrop keyed out to transparency |
| `--no-trim`, `--filter`, `--per-frame`, `--paid` | | see [REFERENCE.md](REFERENCE.md) |

## How the frames are made

One image call produces a **horizontal sprite sheet** of all N frames, which `gif.sh` then cuts up.
Not N separate calls: image quota is small and daily, and a model that draws every frame in one
picture keeps the subject consistent, while one asked for "frame 3 of 8" redraws it from scratch.
`--per-frame` exists for the rare case where a sheet fails, and is worse at consistency.

The model cannot output transparency, so the prompt asks for a flat magenta `#FF00FF` backdrop and
`gif.sh` keys it out. That is why a magenta subject needs `--matte` changed to another color.

## Working with it

**Look at the result before reporting it done.** `gif.sh probe` prints size, frame count, real
duration, loop flag and whether transparency survived; that catches a broken *file*, not a bad
*animation*. For the animation itself, view the frames — pass `--keep-frames` and read the PNGs.

The sheet is the part that fails. A model may draw 7 frames instead of 8, or pad the row unevenly,
and the cut then lands mid-subject. `gif.sh` warns when the sheet aspect ratio is far from what the
frame count implies, but it cannot see misalignment — you can. When it happens: re-cut the kept sheet with
`gif.sh sheet sheet.png out.gif --cols <what the sheet actually has>` rather than regenerating and
spending quota again.

Ask before `--paid`. The free paths cost nothing; OpenRouter spends real credit.

Detail on the pipeline, the tiny-size rules and every failure mode is in
[REFERENCE.md](REFERENCE.md). Needs `python3` + Pillow, and `delegate.sh` on PATH for generation
(assembling your own frames does not need it).
