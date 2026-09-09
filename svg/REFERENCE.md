# svg — reference

Details behind [SKILL.md](SKILL.md). Read when output looks wrong or a flag needs explaining.

## The pipeline

`svg.sh` prompts and retries; `svgpack.py` (Python stdlib only) does everything to the source. Per
run:

1. **Ask** — one `delegate.sh <tier>` text call. The prompt fixes the coordinate space
   (`viewBox="0 0 100 100"`), the style, the animation technique (SMIL, not CSS), the loop length,
   the background, and bans raster embeds, scripts and web fonts.
2. **Extract** — from the first `<svg` to the last `</svg>`, so prose, fences and a chatty preamble
   fall away.
3. **Refuse** — a `DOCTYPE` or `ENTITY` anywhere in the reply fails the build. That is the
   entity-expansion and external-entity door, and no generated icon needs one.
4. **Sanitize** — remove `<script>`, `<foreignObject>`, `<handler>`, every `on*` attribute,
   `javascript:` values, `@import`, and any `href` that is not a `#fragment` (so no external images,
   sprites or trackers). `--allow-raster` keeps `data:image/…` hrefs; nothing keeps a remote URL.
5. **Normalize** — keep the model's viewBox when it is usable (that is the drawing's coordinate
   space), set `width`/`height` to `--size`, add `preserveAspectRatio`.
6. **Background** — remove any full-canvas opaque rect for the transparent default, or insert one
   for `--bg`. Models add a backdrop tile unasked; on an icon that is a bug.
7. **Retime** — see below.
8. **Round** — coordinates to `--round` decimals (default 2) in geometry attributes only, never in
   ids or text. `--round -1` leaves numbers alone.

## Timing

The cycle length is `max(begin + dur)` over the SMIL elements. Every `dur` and numeric `begin` is
scaled by `target / cycle`, so one loop lasts exactly `--duration` **and the choreography survives**:
three bars staggered 0 / 0.2 / 0.4s inside a 1.6s cycle become 0 / 0.125 / 0.25s inside 1.0s.
Rewriting each `dur` to the target instead — the obvious shortcut — collapses that stagger into a
single beat.

`repeatCount="indefinite"` (or `--loop N`) is set on any animation that declares neither
`repeatCount` nor `repeatDur`; without it SMIL plays once and freezes, which is never what "a looping
icon" means.

**CSS animations are second-class.** The prompt asks for SMIL because it is what the retiming can
reason about. If a model returns `@keyframes` anyway, the build succeeds, iteration count is forced
to infinite, and a warning says the duration is *not* enforced. Regenerate if the exact loop length
matters.

`--still` removes SMIL elements, `@keyframes` blocks, `animation`/`transition` declarations and
inline animation styles, so a still is genuinely static rather than merely paused on frame 0.

## Sizes

The art is drawn in a 0 0 100 100 coordinate space and `width`/`height` carry the pixel size, so the
file scales anywhere — `--size` sets the intrinsic size and, more importantly, tells the model what
it has to stay legible at. At 16px, ask for one shape and one accent; detail that survives 128px
turns to mush at 16px, and no amount of vector precision changes that.

A non-square viewBox is kept and letterboxed with `preserveAspectRatio`, with a warning.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `no <svg> element in the input` | the model answered with prose or refused | `--keep-raw` and read it; retry a tier up |
| `the SVG does not parse` | truncated or malformed reply | retry; `--tier hard` for complex subjects |
| `no animation … and --still was not given` | model drew a static icon | that is the retry loop working; or pass `--still` |
| `removed N full-canvas background rect(s)` | model drew a backdrop | expected on the transparent default |
| Warning about stripped content | script, handler or external href in the reply | expected; the file written is clean |
| Animation is CSS-only | model ignored the SMIL instruction | regenerate if exact duration matters |
| Loop stutters at the seam | last animation value ≠ first | regenerate; the prompt asks for it, models still miss it |
| `could not get a usable SVG` | every attempt was rejected | `--retries 2`, `--tier hard`, or write it yourself and use `svg.sh build` |

`svg.sh probe` re-reads a finished file and reports size, viewBox, element count, animation and
cycle, loop, background and anything unsafe — **exiting 1 when it finds something unsafe**, so it
doubles as a lint for SVGs from anywhere, not only ones this skill produced.

## Preview

`svg.sh preview file.svg out.png` uses the first rasterizer it finds: `rsvg-convert`, ImageMagick,
Inkscape, then headless Chrome. It renders **frame 0 only** — enough to see whether the drawing is
right; the animation needs a browser. `$CHROME` picks a specific binary, `$CHROME_FLAGS` passes extra
flags (a container running as root needs `--no-sandbox`; that is not on by default for a reason).

## Dependencies

`python3` — stdlib only, no Pillow, no ImageMagick, no network. `delegate.sh` on `PATH` only for
generation; `build`, `probe` and `preview` work without it. `$PYTHON` overrides the interpreter.
`svgpack.py` is usable on its own (`python3 svgpack.py build|probe --help`) if you want the pipeline
without the prompting.
