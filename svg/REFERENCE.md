# svg — reference

Details behind [SKILL.md](SKILL.md). Read when output looks wrong or a flag needs explaining.

## The pipeline

`svg.sh` prompts and retries; `svgpack.py` (Python stdlib only) does everything to the source. Per
run:

1. **Ask** — one `delegate.sh <tier>` text call. The prompt fixes the coordinate space
   (`viewBox="0 0 100 100"`), the style, the animation technique, the loop length, the background,
   and bans raster embeds, scripts and web fonts.
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

## Why CSS is the default

Both CSS and SMIL animate in a browser, inline or in an `<img>`, and both are ignored by every
rasterizer (librsvg, ImageMagick, Inkscape render frame 0) and by design tools. What separates them:

- **CSS can express `prefers-reduced-motion`; SMIL cannot.** A looping icon is exactly the motion
  that setting exists for.
- **CSS is restyleable from the host page** when the SVG is inlined — speed, colours, pause on
  hover — and the prompt keeps colours as presentation attributes so the stylesheet holds only motion.
- **Models write CSS animation more fluently** than SMIL, so first attempts land more often.
- SMIL's advantages are real but narrower: fully self-contained (no host CSS can reach it) and
  seekable with `setCurrentTime`, which is how this skill's own tests step through a loop. `--smil`
  when you want that.

## Timing

The cycle length is the **longest duration**, not `begin + dur` (nor `delay + duration`). A repeating
animation restarts every duration; a delay only offsets when it first starts. So a bar delayed 0.4s
inside a 1.2s animation is a phase shift *within* a 1.2s loop, and treating it as a 1.6s one makes a
staggered loader run faster than the duration asked for.

Every duration and delay is then scaled by `target / cycle`, which keeps each element's phase at the
same fraction of the loop: three dots at 0 / 0.2 / 0.4s of a 1.2s loop become 0 / 0.1667 / 0.3333s of
a 1.0s loop. Rewriting each duration to the target instead — the obvious shortcut — collapses the
stagger into a single beat. `@keyframes` offsets are percentages, so they need no touching.

The iteration count is forced (`repeatCount="indefinite"` for SMIL, `animation-iteration-count` for
CSS, or `--loop N`): without it SMIL plays once and freezes, which is never what "a looping icon"
means. A file that arrives with both CSS and SMIL animation gets both normalized, and `probe` says so.

`--still` removes SMIL elements, `@keyframes` blocks, `animation`/`transition` declarations and
inline animation styles, so a still is genuinely static rather than merely paused on frame 0.

## Reduced motion

Every animated build appends
`@media (prefers-reduced-motion: reduce) { * { animation: none !important } }` (frame sequences get a
variant that holds frame 0 rather than a blank canvas). `--no-reduced-motion` omits it.

**Where it actually takes effect:** verified honoured when the SVG is inlined into a page or opened
directly, and *not* honoured in Chromium when the same file is loaded through `<img src="icon.svg">`
— the embedded document keeps animating. If respecting the setting matters, inline the SVG rather
than referencing it.

## Frame-by-frame (`--frames N`)

The model is asked for N sibling `<g>` groups — one drawing per moment, no animation of any kind —
and this script writes the timing: one `step-end` animation of `--duration`, a keyframe pair that
holds each frame for `100/N` percent, and a negative `animation-delay` per frame that offsets it into
its own slot. Step-end rather than the default easing, so frames swap instead of cross-fading.

That split matters: asking a model for per-frame keyframes is asking it to do arithmetic it gets
wrong, while asking it for N drawings is asking it to draw. `--keep-frames DIR` also writes each
frame as its own still SVG, which is what a renderer that ignores animation can use — and what feeds
the `gif` skill after rasterizing:

```bash
svg.sh make "a walking robot" walk.svg --frames 8 --keep-frames ./frames
for f in ./frames/*.svg; do svg.sh preview "$f" "${f%.svg}.png" --width 256; done
gif.sh frames walk.gif ./frames --size 64 --matte none
```

Use it when motion cannot be interpolated (a sprite gait, a dial ticking through positions), or when
the frames themselves are the deliverable. For a spin, a pulse or a bounce, the CSS default is
smaller and smoother.

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
| `no animation … and neither --still nor --frames` | model drew a static icon | that is the retry loop working; or pass `--still` |
| `expected N frame group(s) … found M` | `--frames` reply has the wrong shape | retry; or split the kept raw reply yourself |
| `removed N full-canvas background rect(s)` | model drew a backdrop | expected on the transparent default |
| Warning about stripped content | script, handler or external href in the reply | expected; the file written is clean |
| Animation is SMIL when you wanted CSS (or vice versa) | model ignored the instruction | both are normalized, so it still works; regenerate if the technique matters |
| Element rotates around the wrong point | CSS transform without `transform-box: fill-box` | the prompt asks for it; regenerate or add it by hand |
| Loop stutters at the seam | last animation value ≠ first | regenerate; the prompt asks for it, models still miss it |
| `could not get a usable SVG` | every attempt was rejected | `--retries 2`, `--tier hard`, or write it yourself and use `svg.sh build` |

`svg.sh probe` re-reads a finished file and reports size, viewBox, element count, animation technique
and cycle, loop, whether reduced motion is honoured, background and anything unsafe — **exiting 1 when it finds something unsafe**, so it
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
