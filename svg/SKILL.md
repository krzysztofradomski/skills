---
name: svg
description: Make small SVG icons - looping animated SMIL by default, or a single still image with --still. Square 16x16, 32x32, 64x64 or 128x128, transparent or on a solid background, loops up to 3 seconds. Asks a delegate text model for the source (plan allowance, free), then sanitizes, resizes and re-times it locally. Use when the user asks for an SVG, a vector icon, a spinner or loader, an animated logo mark, a favicon, or wants an icon they can restyle in code afterwards.
---

# SVG

An SVG is **code**, so it comes from a delegate *text* tier rather than an image model: it costs plan
allowance instead of the small daily image quota, and the result is reviewable, diffable and
editable. `svg.sh` then does the part a model cannot be trusted with — stripping anything executable,
fixing the size, and making the loop last exactly as long as you asked.

## Quick start

```bash
svg.sh make "a ringing notification bell" bell.svg       # 32px, transparent, 1s loop, forever
svg.sh still "a bell" bell.svg                           # one static image, no animation
svg.sh make "a loading spinner" spin.svg --size 64 --duration 1.5
svg.sh make "a coin" coin.svg --bg '#0b1020' --tier hard
svg.sh build out.svg reply.txt --still                   # normalize SVG you already have (or -)
svg.sh probe out.svg                                     # what the file contains; exits 1 if unsafe
svg.sh preview out.svg out.png --width 512               # rasterize frame 0 so you can look at it
svg.sh check                                             # dependencies
```

**Defaults: 32x32, transparent, animated, 1.0s cycle, loops forever.** `--still` (or the `still`
verb) drops every animation. Sizes are restricted to 16 / 32 / 64 / 128 and duration to 3s.

| Flag | Default | |
|---|---|---|
| `--still` | off | single static image; `svg.sh still …` is the same thing |
| `--size 16\|32\|64\|128` | 32 | sets width/height; the art is drawn in a 0 0 100 100 viewBox |
| `--duration SEC` | 1 | max 3; every SMIL time is scaled so one cycle is exactly this |
| `--loop N` | 0 | 0 = forever |
| `--bg COLOR` / `--opaque` | transparent | a full-canvas rect; without it, one the model drew is removed |
| `--tier cheap\|read\|code\|hard\|or\|codex` | code | which delegate tier writes it |
| `--style "..."` | flat vector | replaces the style sentence in the prompt |
| `--keep-raw FILE`, `--retries N`, `--round N`, `--title`, `--allow-raster` | | see [REFERENCE.md](REFERENCE.md) |

## What happens to the model's answer

Never trusted as-is. `svg.sh` extracts the SVG from the prose or fences around it, refuses a DOCTYPE
outright, and strips `<script>`, `<foreignObject>`, every `on*` handler, `javascript:` URLs, external
and `data:` `href`s, and CSS `@import` — then normalizes size and viewBox, applies or removes the
background, **scales every animation time so the cycle is exactly `--duration`** (preserving the
stagger between elements rather than flattening it), and forces `repeatCount` so the loop actually
loops. A reply with no animation and no `--still` is rejected rather than quietly shipped.

Rejections are re-asked, once by default, with the error handed back to the model and the tier
escalated (`code` → `hard`). Retries cost plan allowance, not your context.

## Working with it

**Look at the result before reporting it done.** `svg.sh probe` tells you what is in the file; it
does not tell you whether the drawing is any good. `svg.sh preview out.svg out.png` rasterizes frame
0 so you can actually read the image — do that. The animation itself only plays in a browser.

When a result is close but wrong, `--keep-raw` keeps the model's reply so you can edit it and re-run
`svg.sh build` instead of regenerating. Editing the SVG by hand is fine too — it is just code — but
run it back through `svg.sh build` afterwards so size, timing and safety are re-enforced.

For a subject that does not animate naturally (a static logo, a flat glyph), use `--still` rather
than accepting a token wobble.

Detail on the sanitizer, the retiming maths and every failure mode is in
[REFERENCE.md](REFERENCE.md). Needs `python3` only (stdlib — no Pillow, no ImageMagick), plus
`delegate.sh` on PATH for generation.
