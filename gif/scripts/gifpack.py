#!/usr/bin/env python3
"""Frame -> GIF pipeline for the `gif` skill. Pillow only; no ImageMagick.

Everything the format itself constrains (1-bit alpha, 10ms delay quantum, one
palette per frame, disposal between frames) is handled here rather than left to
the caller, because getting any of it wrong produces a GIF that still opens and
still looks broken.
"""
import argparse
import math
import os
import signal
import sys
import urllib.parse

try:
    from PIL import Image
except ImportError:
    sys.exit("gifpack: Pillow is required -- pip install pillow, or brew install pillow on Homebrew python")

def linked(path):
    """The path as an OSC 8 hyperlink, so a terminal that supports them opens the file on a
    click. Plain text when stdout is not a terminal, which keeps captured output parsable."""
    if not sys.stdout.isatty():
        return path
    url = "file://" + urllib.parse.quote(os.path.abspath(path))
    return "\033]8;;%s\033\\%s\033]8;;\033\\" % (url, path)


SIZES = (16, 32, 64, 128)
MAX_DURATION = 3.0
MAX_DIST = math.sqrt(3 * 255 ** 2)


def die(msg):
    sys.exit("gifpack: " + msg)


def parse_color(s):
    """#rgb, #rrggbb or r,g,b -> (r, g, b)."""
    s = s.strip()
    if s.startswith("#"):
        h = s[1:]
        if len(h) == 3:
            h = "".join(c * 2 for c in h)
        if len(h) != 6:
            die("bad color %r (want #rgb, #rrggbb or r,g,b)" % s)
        try:
            return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
        except ValueError:
            die("bad color %r" % s)
    parts = s.split(",")
    if len(parts) == 3:
        try:
            return tuple(max(0, min(255, int(p))) for p in parts)
        except ValueError:
            pass
    die("bad color %r (want #rgb, #rrggbb or r,g,b)" % s)


def key_matte(im, matte, fuzz):
    """Punch the flat backdrop out to alpha 0.

    Image models will not give us real transparency, so we ask them for a flat
    magenta backdrop and remove it here. Tolerance is a share of the RGB
    diagonal, so --fuzz reads the same whatever the matte color is.
    """
    tol2 = ((fuzz / 100.0) * MAX_DIST) ** 2
    mr, mg, mb = matte
    data = bytearray(im.tobytes())
    for i in range(0, len(data), 4):
        if data[i + 3]:
            dr, dg, db = data[i] - mr, data[i + 1] - mg, data[i + 2] - mb
            if dr * dr + dg * dg + db * db <= tol2:
                data[i + 3] = 0
    im.frombytes(bytes(data))
    return im


def common_bbox(frames):
    """One crop box for every frame.

    Cropping each frame to its own content would re-center the subject frame by
    frame and cancel out the motion, so the union of the boxes is used.
    """
    box = None
    for im in frames:
        b = im.getchannel("A").getbbox()
        if b is None:
            continue
        box = b if box is None else (min(box[0], b[0]), min(box[1], b[1]),
                                     max(box[2], b[2]), max(box[3], b[3]))
    return box


def fit_square(im, size, resample):
    """Scale to fit, then center on a square transparent canvas."""
    w, h = im.size
    scale = min(size / w, size / h)
    nw, nh = max(1, round(w * scale)), max(1, round(h * scale))
    im = im.resize((nw, nh), resample)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(im, ((size - nw) // 2, (size - nh) // 2))
    return canvas


def frame_delays(duration, n):
    """Per-frame delays in ms, summing to exactly the requested duration.

    GIF stores delay in centiseconds, so 1s over 8 frames is 12.5cs and cannot
    be uniform. The remainder is spread over the first frames instead of being
    rounded away, which would drift the loop length.
    """
    total_cs = int(round(duration * 100))
    base, rem = divmod(total_cs, n)
    if base < 2:
        die("%d frames in %.2fs is %dcs per frame; browsers clamp anything under "
            "2cs to 10cs. Use fewer frames (max %d) or a longer --duration."
            % (n, duration, base, int(duration * 50)))
    return [(base + (1 if i < rem else 0)) * 10 for i in range(n)]


def build_palette(frames, colors):
    """One palette shared by every frame, built from opaque pixels only.

    A per-frame palette makes flat colors shimmer between frames, and feeding
    the transparent pixels in would spend palette slots on pixels nobody sees.
    """
    px = bytearray()
    for im in frames:
        raw = im.tobytes()
        for i in range(0, len(raw), 4):
            if raw[i + 3]:
                px += raw[i:i + 3]
    if not px:
        die("every frame is fully transparent -- the matte key removed the whole "
            "image. Lower --fuzz, or check the source really has a flat backdrop.")
    n = len(px) // 3
    w = max(1, int(math.ceil(math.sqrt(n))))
    h = int(math.ceil(n / w))
    px += px[:3] * (w * h - n)          # pad the last row with a color already present
    comp = Image.frombytes("RGB", (w, h), bytes(px))
    return comp.quantize(colors=colors, method=Image.MEDIANCUT, dither=Image.Dither.NONE)


def cmd_build(a):
    if a.size not in SIZES:
        die("--size must be one of %s (got %d)" % ("/".join(map(str, SIZES)), a.size))
    if not 0 < a.duration <= MAX_DURATION:
        die("--duration must be >0 and <=%.0fs (got %.3f)" % (MAX_DURATION, a.duration))
    if not 2 <= a.colors <= 256:
        die("--colors must be 2..256")
    if not a.frames:
        die("no input frames")
    delays = frame_delays(a.duration, len(a.frames))   # fail before any pixel work

    transparent = not a.opaque
    bg = parse_color(a.bg) if a.bg else (255, 255, 255)
    matte = parse_color(a.matte) if a.matte and a.matte.lower() != "none" else None
    resample = {"auto": None, "box": Image.BOX, "lanczos": Image.LANCZOS,
                "nearest": Image.NEAREST}[a.filter]
    if resample is None:  # area-averaging reads cleaner below 64px, Lanczos above
        resample = Image.BOX if a.size <= 32 else Image.LANCZOS

    frames = []
    for p in a.frames:
        try:
            frames.append(Image.open(p).convert("RGBA"))
        except OSError as e:
            die("cannot read frame %s: %s" % (p, e))
    if matte:
        frames = [key_matte(im, matte, a.fuzz) for im in frames]

    if not a.no_trim:
        box = common_bbox(frames)
        if box and box != (0, 0) + frames[0].size:
            frames = [im.crop(box) for im in frames]
    frames = [fit_square(im, a.size, resample) for im in frames]

    # GIF alpha is one bit: anything partial has to become fully on or fully off
    # here, or Pillow picks the threshold for us and edges turn to mud.
    for im in frames:
        alpha = im.getchannel("A").point(lambda v: 255 if v >= a.alpha_threshold else 0)
        im.putalpha(alpha)

    if transparent:
        tidx = a.colors - 1
        pal_src = build_palette(frames, a.colors - 1)
        palette = pal_src.getpalette()[: (a.colors - 1) * 3] + list(bg)
        out = []
        for im in frames:
            flat = Image.new("RGB", im.size, (0, 0, 0))
            flat.paste(im, mask=im.getchannel("A"))
            p = flat.quantize(palette=pal_src, dither=Image.Dither.NONE)
            data = bytearray(p.tobytes())
            rgba = im.tobytes()
            for i in range(len(data)):
                if not rgba[i * 4 + 3]:
                    data[i] = tidx
            p.frombytes(bytes(data))
            p.putpalette(palette)
            out.append(p)
        save_kw = dict(transparency=tidx, disposal=2)
    else:
        flat_frames = []
        for im in frames:
            flat = Image.new("RGB", im.size, bg)
            flat.paste(im, mask=im.getchannel("A"))
            flat_frames.append(flat.convert("RGBA"))
        pal_src = build_palette(flat_frames, a.colors)
        out = [f.convert("RGB").quantize(palette=pal_src, dither=Image.Dither.NONE)
               for f in flat_frames]
        save_kw = dict(disposal=1)

    os.makedirs(os.path.dirname(os.path.abspath(a.out)) or ".", exist_ok=True)
    out[0].save(a.out, save_all=True, append_images=out[1:], duration=delays,
                loop=a.loop, optimize=False, **save_kw)
    # The encoder merges runs of identical frames and sums their delays, so the
    # file can hold fewer frames than we passed. Report what it actually holds.
    written = getattr(Image.open(a.out), "n_frames", len(out))
    print("wrote %s (%dx%d, %d frame%s, %.2fs, loop=%s, %s)"
          % (linked(a.out), a.size, a.size, written, "" if written == 1 else "s", sum(delays) / 1000.0,
             "forever" if a.loop == 0 else a.loop,
             "transparent" if transparent else "opaque"))


def grid_for(w, h, count):
    """The (cols, rows) arrangement of `count` square frames that best explains a w x h sheet."""
    best = None
    for cols in range(1, count + 1):
        if count % cols:
            continue
        rows = count // cols
        cell = (w * 1.0 / cols) / (h * 1.0 / rows)      # 1.0 when the cell is square
        score = abs(math.log(cell))
        if best is None or score < best[0]:
            best = (score, cols, rows)
    return best[1], best[2]


def cmd_slice(a):
    try:
        sheet = Image.open(a.sheet).convert("RGBA")
    except OSError as e:
        die("cannot read sheet %s: %s" % (a.sheet, e))
    w, h = sheet.size
    cols, rows = a.cols, a.rows
    if not cols:
        # Ask for one row of N and the model still lays them out as a grid whenever N is
        # composite. The frames are square, so the arrangement it chose is the factor pair
        # whose cells come out closest to square -- and a wrong guess here does not merely
        # look off: every cell straddles two frames, so the matte no longer lines up and
        # the key leaves the backdrop behind.
        cols, rows = grid_for(w, h, a.count)
        if cols * rows == a.count and (cols, rows) != (a.count, 1):
            print("gifpack: sheet is %dx%d, reading it as %d x %d" % (w, h, cols, rows),
                  file=sys.stderr)
    if cols * rows < a.count:
        die("--cols %d x --rows %d cannot hold %d frames" % (cols, rows, a.count))
    fw, fh = w // cols, h // rows
    if fw == 0 or fh == 0:
        die("sheet %dx%d is too small to cut into %dx%d cells" % (w, h, cols, rows))
    # Even the best arrangement can be wrong if the model drew something else entirely.
    # Warn rather than fail: the cut may still be usable, and the caller can look.
    if not 0.7 <= (fw * 1.0) / fh <= 1.43:
        print("gifpack: warning: cutting %dx%d into %d x %d gives %dx%d cells, which are not "
              "square; frames are probably misaligned" % (w, h, cols, rows, fw, fh),
              file=sys.stderr)
    os.makedirs(a.outdir, exist_ok=True)
    n = 0
    for r in range(rows):
        for c in range(cols):
            if n >= a.count:
                break
            p = os.path.join(a.outdir, "frame_%02d.png" % n)
            sheet.crop((c * fw, r * fh, (c + 1) * fw, (r + 1) * fh)).save(p)
            print(p)
            n += 1


def cmd_probe(a):
    try:
        im = Image.open(a.gif)
    except OSError as e:
        die("cannot read %s: %s" % (a.gif, e))
    delays, n = [], 0
    try:
        while True:
            im.seek(n)
            delays.append(im.info.get("duration", 0))
            n += 1
    except EOFError:
        pass
    im.seek(0)
    loop = im.info.get("loop", None)
    print("file        %s" % a.gif)
    print("format      %s%s" % (im.format, "" if im.format == "GIF" else "   <- not a GIF"))
    print("size        %dx%d" % im.size)
    print("frames      %d" % n)
    print("duration    %.2fs  (delays ms: %s)" % (sum(delays) / 1000.0, delays))
    print("loop        %s" % ("forever" if loop == 0 else ("once (no loop block)" if loop is None else loop)))
    print("transparent %s" % ("yes (index %s)" % im.info["transparency"]
                              if "transparency" in im.info else "no"))
    print("bytes       %d" % os.path.getsize(a.gif))
    if im.size[0] != im.size[1]:
        print("gifpack: warning: not square", file=sys.stderr)


def main():
    # Piping output into `head` should not print a traceback.
    if hasattr(signal, "SIGPIPE"):
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    ap = argparse.ArgumentParser(prog="gifpack")
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="assemble frames into a looping GIF")
    b.add_argument("out")
    b.add_argument("frames", nargs="+")
    b.add_argument("--size", type=int, default=32)
    b.add_argument("--duration", type=float, default=1.0)
    b.add_argument("--loop", type=int, default=0)
    b.add_argument("--colors", type=int, default=64)
    b.add_argument("--opaque", action="store_true")
    b.add_argument("--bg", default=None, help="background for --opaque (default white)")
    b.add_argument("--matte", default="#FF00FF", help="backdrop color to key out; 'none' to keep")
    b.add_argument("--fuzz", type=float, default=18.0, help="matte tolerance, %% (default 18)")
    b.add_argument("--alpha-threshold", type=int, default=128)
    b.add_argument("--no-trim", action="store_true")
    b.add_argument("--filter", choices=("auto", "box", "lanczos", "nearest"), default="auto")
    b.set_defaults(func=cmd_build)

    s = sub.add_parser("slice", help="cut a sprite sheet into frames")
    s.add_argument("sheet")
    s.add_argument("outdir")
    s.add_argument("--cols", type=int, default=0)   # 0 = work it out from the sheet
    s.add_argument("--rows", type=int, default=1)
    s.add_argument("--count", type=int, default=0)
    s.set_defaults(func=cmd_slice)

    p = sub.add_parser("probe", help="report what a GIF actually contains")
    p.add_argument("gif")
    p.set_defaults(func=cmd_probe)

    a = ap.parse_args()
    if a.cmd == "slice" and not a.count:
        a.count = a.cols * a.rows
    a.func(a)


if __name__ == "__main__":
    main()
