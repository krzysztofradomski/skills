# gif — reference

Details behind [SKILL.md](SKILL.md). Read when output looks wrong or a flag needs explaining.

## The pipeline

`gif.sh` orchestrates and prompts; `gifpack.py` (Pillow) does the pixels. Per run:

1. **Generate** — one `delegate.sh image` call for a horizontal sprite sheet, or N calls with
   `--per-frame`.
2. **Slice** — the sheet is cut into `--frames` equal columns by width, left to right.
3. **Key** — pixels within `--fuzz` of `--matte` become transparent.
4. **Trim** — one crop box, the *union* of every frame's content box, applied to all frames.
   Cropping each frame to its own bounds would re-centre the subject frame by frame and cancel the
   motion out. `--no-trim` keeps the original framing.
5. **Fit** — scaled to fit and centred on a square canvas, so a non-square sheet cell still yields a
   square GIF.
6. **Threshold** — GIF alpha is one bit, so partial alpha is forced to fully on or fully off at
   `--alpha-threshold` (128). Left to the encoder this is where soft edges turn to mud.
7. **Quantize** — one palette shared by every frame, built from opaque pixels only. Per-frame
   palettes make flat colors shimmer between frames; feeding transparent pixels in spends palette
   slots on pixels nobody sees.
8. **Encode** — per-frame delays in ms, `disposal=2` (restore to background) when transparent so
   frames do not smear into each other, `disposal=1` when opaque.

## Timing

GIF stores delay in **centiseconds**, so 1s across 8 frames is 12.5cs and cannot be uniform. The
remainder is spread over the leading frames (`[130,130,130,130,120,120,120,120]` ms) rather than
rounded away, which would drift the loop length by up to half a frame.

Browsers clamp any delay under 2cs to 10cs, so a frame count that would need faster than 50fps is
refused with the maximum that fits your `--duration` instead of producing a GIF that plays at a
different speed than requested. In practice: **50 frames per second of duration** is the ceiling.

Runs of **identical consecutive frames are merged** by the encoder and their delays summed, so
`probe` can report fewer frames than you passed in. Total duration and playback are unchanged; it
only means two of your frames were byte-identical after quantization.

`--loop 0` (the default) writes an infinite Netscape loop block; `--loop N` plays N times. There is
no "play once" flag — pass `--loop 1`.

## Transparency

Image models do not emit alpha, so the prompt demands a flat `#FF00FF` backdrop and the key removes
it. Consequences worth knowing:

- **A magenta subject loses its magenta.** Pass `--matte '#00FF00'` (or any color absent from the
  subject) — the same color goes into the prompt and into the key, so they stay in sync.
- **`--fuzz` too high eats the subject**; too low leaves a magenta fringe where the model
  anti-aliased its own edges. 18% handles most output. A fully-keyed image fails loudly rather than
  writing an empty GIF.
- **Frames you supply yourself** usually already have alpha: pass `--matte none` so nothing is keyed.
- `--opaque` / `--bg` still key the matte first, then flatten onto the background color — so a
  generated frame's magenta backdrop becomes your color rather than staying magenta.

## Tiny sizes

At 16x16 and 32x32 a detailed illustration turns to noise, which is why the default prompt asks for
flat pixel art with a strong silhouette. Downscaling uses area averaging (`BOX`) at ≤32px and
Lanczos above; `--filter nearest` gives harder pixel edges, `--filter lanczos` more detail at 16px
than it can actually hold. `--colors` below ~32 gives a deliberately flat retro palette; above ~128
mostly grows the file.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Subject jumps around between frames | model redrew it per cell | regenerate; or `--keep-frames` and re-cut |
| Frames cut mid-subject | sheet has a different frame count than asked | `gif.sh sheet <kept sheet> out.gif --cols <actual>` |
| Magenta fringe on edges | anti-aliased matte | raise `--fuzz` |
| Subject has holes | `--fuzz` too high, or subject shares the matte color | lower `--fuzz`, or change `--matte` |
| Whole image transparent | matte key removed everything | as above; the script refuses to write it |
| `delegate could not generate` | daily image quota spent | retry later, or supply frames yourself |
| Warning about sheet aspect ratio | cut is probably misaligned | inspect with `--keep-frames` |

`gif.sh probe` re-reads the finished file and reports what is actually in it — size, frame count,
per-frame delays, loop block, transparency index, bytes. Trust it over the "wrote …" line, which
only reports intent.

## Dependencies

`python3` and Pillow (`pip install pillow`) for everything; `delegate.sh` on `PATH` only for
generation. No ImageMagick, no ffmpeg, no network. `$PYTHON` overrides the interpreter.
`gifpack.py` is usable on its own (`python3 gifpack.py build|slice|probe --help`) if you want the pipeline
without the prompting.
