#!/usr/bin/env python3
"""Model output -> a safe, correctly sized, correctly timed SVG.

Stdlib only. A model hands back prose wrapped around code, sometimes with a
script tag, an external image, a DOCTYPE, a stray width, or an animation that
runs for however long it felt like. Everything here is one of those, turned into
a rule instead of a hope.
"""
import argparse
import os
import re
import signal
import sys
import xml.etree.ElementTree as ET

SVG_NS = "http://www.w3.org/2000/svg"
XLINK_NS = "http://www.w3.org/1999/xlink"
SIZES = (16, 32, 64, 128)
MAX_DURATION = 3.0

ANIM_TAGS = {"animate", "animateTransform", "animateMotion", "animateColor", "set"}
# Round only attributes whose whole value is a coordinate list; never text or ids.
ROUND_ATTRS = {"d", "points", "transform", "x", "y", "cx", "cy", "r", "rx", "ry",
               "width", "height", "x1", "y1", "x2", "y2", "fx", "fy",
               "stroke-width", "stroke-dasharray", "stroke-dashoffset", "offset"}
NUM_RE = re.compile(r"-?\d+\.\d+")
TIME_RE = re.compile(r"^\s*(-?\d*\.?\d+)\s*(ms|s)?\s*$")


def die(msg):
    sys.exit("svgpack: " + msg)


def warn(msg):
    print("svgpack: warning: " + msg, file=sys.stderr)


def local(tag):
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


def parse_color(s):
    s = s.strip()
    if re.fullmatch(r"#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6}|[a-zA-Z]+|rgba?\([^)]*\)", s):
        return s
    die("bad color %r (want #rgb, #rrggbb, a CSS name, or rgb()/rgba())" % s)


def parse_time(v):
    """SMIL clock value -> seconds, or None if it is not a plain offset."""
    m = TIME_RE.match(v or "")
    if not m:
        return None
    n = float(m.group(1))
    return n / 1000.0 if m.group(2) == "ms" else n


def fmt_time(sec):
    return ("%.4f" % sec).rstrip("0").rstrip(".") + "s"


# ---------------------------------------------------------------- extraction

def extract(text):
    """Pull the SVG out of whatever the model wrapped around it.

    Models answer with prose, fenced code blocks, sometimes an XML declaration,
    sometimes two candidate SVGs. Take the outermost first `<svg ...>` through
    the last `</svg>`, which is the whole document even when it nests symbols.
    """
    start = text.find("<svg")
    end = text.rfind("</svg>")
    if start < 0 or end < 0 or end < start:
        die("no <svg> element in the input (%d bytes). The model answered with "
            "something else -- keep the raw reply and look at it." % len(text))
    return text[start:end + len("</svg>")]


def reject_doctype(src):
    """No DTD, ever: it is the entity-expansion and external-entity door, and no
    legitimate generated icon needs one."""
    if re.search(r"<!DOCTYPE", src, re.I) or re.search(r"<!ENTITY", src, re.I):
        die("input contains a DOCTYPE or ENTITY declaration; refusing to parse it")


# ---------------------------------------------------------------- sanitizing

def sanitize(root, allow_raster=False):
    """Remove everything that makes an SVG more than a picture."""
    removed = []
    parents = {c: p for p in root.iter() for c in p}

    for el in list(root.iter()):
        t = local(el.tag)
        if t in ("script", "foreignObject", "handler"):
            p = parents.get(el)
            if p is not None:
                p.remove(el)
                removed.append("<%s>" % t)
            continue
        for name in list(el.attrib):
            ln = local(name)
            val = el.attrib[name]
            if ln.startswith("on"):                       # onclick, onload, ...
                del el.attrib[name]
                removed.append("@" + ln)
            elif ln in ("href", "xlink:href") or name.endswith("}href"):
                v = val.strip()
                if v.startswith("#"):
                    continue                              # internal reference: fine
                if allow_raster and v.startswith("data:image/"):
                    continue
                del el.attrib[name]
                removed.append("href=%s" % (v[:24] + ("..." if len(v) > 24 else "")))
            elif "javascript:" in val.lower():
                del el.attrib[name]
                removed.append("@" + ln)

    for st in root.iter("{%s}style" % SVG_NS):
        if st.text and "@import" in st.text:
            st.text = re.sub(r"@import[^;]*;", "", st.text)
            removed.append("@import")
    return removed


# ---------------------------------------------------------------- animation

def anim_elements(root):
    return [el for el in root.iter() if local(el.tag) in ANIM_TAGS]


def css_blocks(root):
    return [st for st in root.iter("{%s}style" % SVG_NS) if st.text]


def has_css_animation(root):
    return any(re.search(r"@keyframes|animation\s*:|animation-name", st.text or "", re.I)
               for st in css_blocks(root))


def strip_animation(root):
    """--still: a still must be genuinely static, not merely paused."""
    n = 0
    parents = {c: p for p in root.iter() for c in p}
    for el in anim_elements(root):
        p = parents.get(el)
        if p is not None:
            p.remove(el)
            n += 1
    for st in css_blocks(root):
        txt = re.sub(r"@keyframes[^{]*\{(?:[^{}]*\{[^{}]*\}\s*)*\}", "", st.text, flags=re.I)
        txt = re.sub(r"(?m)^\s*(animation|transition)[^;]*;", "", txt, flags=re.I)
        st.text = txt
        n += 1 if txt != st.text else 0
    for el in root.iter():
        s = el.get("style")
        if s and re.search(r"animation|transition", s, re.I):
            el.set("style", re.sub(r"(?:animation|transition)[^;]*;?", "", s, flags=re.I))
    return n


def cycle_length(anims):
    """Longest begin+dur across the SMIL elements: the loop's real period."""
    longest = 0.0
    for el in anims:
        d = parse_time(el.get("dur", ""))
        b = parse_time((el.get("begin", "0") or "0").split(";")[0])
        if d is None:
            continue
        longest = max(longest, (b or 0.0) + d)
    return longest


def retime(anims, target):
    """Scale every offset so one cycle lasts exactly --duration.

    Rewriting each dur to the target instead would flatten staggered timing into
    a single beat; scaling keeps the choreography and only changes the tempo.
    """
    cur = cycle_length(anims)
    if cur <= 0:
        return None
    factor = target / cur
    if abs(factor - 1.0) < 0.001:
        return 1.0
    for el in anims:
        d = parse_time(el.get("dur", ""))
        if d is not None:
            el.set("dur", fmt_time(d * factor))
        b = el.get("begin")
        if b:
            parts = []
            for piece in b.split(";"):
                t = parse_time(piece)
                parts.append(fmt_time(t * factor) if t is not None else piece.strip())
            el.set("begin", ";".join(parts))
    return factor


def set_loop(root, anims, loop):
    """SMIL: an animation with no repeatCount plays once and freezes, which is
    never what 'a looping icon' means."""
    count = "indefinite" if loop == 0 else str(loop)
    for el in anims:
        if not el.get("repeatCount") and not el.get("repeatDur"):
            el.set("repeatCount", count)
    if has_css_animation(root):
        css_count = "infinite" if loop == 0 else str(loop)
        st = css_blocks(root)[0]
        # Only elements that already declare an animation are affected by this.
        st.text = (st.text or "") + "\n* { animation-iteration-count: %s; }\n" % css_count


# ---------------------------------------------------------------- geometry

def normalize_root(root, size):
    root.tag = "{%s}svg" % SVG_NS
    vb = root.get("viewBox")
    if vb:
        nums = [float(n) for n in re.split(r"[\s,]+", vb.strip()) if n]
        if len(nums) != 4 or nums[2] <= 0 or nums[3] <= 0:
            warn("viewBox %r is unusable; replacing it with 0 0 %d %d" % (vb, size, size))
            vb = None
        elif abs(nums[2] - nums[3]) > 0.01 * max(nums[2], nums[3]):
            warn("viewBox is %g x %g, not square; the art will be letterboxed into the "
                 "square canvas" % (nums[2], nums[3]))
    if not vb:
        w, h = root.get("width"), root.get("height")
        try:
            vb = "0 0 %s %s" % (float(re.sub(r"[a-z%]+$", "", w or "")),
                                float(re.sub(r"[a-z%]+$", "", h or "")))
        except (TypeError, ValueError):
            vb = "0 0 %d %d" % (size, size)
    root.set("viewBox", vb.strip())
    root.set("width", str(size))
    root.set("height", str(size))
    root.set("preserveAspectRatio", root.get("preserveAspectRatio", "xMidYMid meet"))
    return [float(n) for n in re.split(r"[\s,]+", root.get("viewBox").strip())]


def covers_canvas(el, vb):
    """Is this a full-bleed background rect?"""
    if local(el.tag) != "rect":
        return False
    try:
        x, y = float(el.get("x", 0)), float(el.get("y", 0))
        w, h = float(el.get("width", 0)), float(el.get("height", 0))
    except ValueError:
        return False
    fill = (el.get("fill") or "").strip().lower()
    if fill in ("none", "transparent"):
        return False
    return (x <= vb[0] + 0.01 and y <= vb[1] + 0.01
            and w >= vb[2] - 0.01 and h >= vb[3] - 0.01)


def apply_background(root, vb, bg):
    """bg=None means transparent, which also means removing the backdrop the
    model drew because it was told to draw an icon and drew a tile."""
    removed = 0
    for el in list(root):
        if covers_canvas(el, vb):
            root.remove(el)
            removed += 1
    if bg:
        rect = ET.Element("{%s}rect" % SVG_NS, {
            "x": "%g" % vb[0], "y": "%g" % vb[1],
            "width": "%g" % vb[2], "height": "%g" % vb[3], "fill": bg})
        root.insert(0, rect)
    return removed


def round_numbers(root, places):
    fmt = "%%.%df" % places

    def shrink(m):
        return (fmt % float(m.group(0))).rstrip("0").rstrip(".") or "0"

    n = 0
    for el in root.iter():
        for name, val in list(el.attrib.items()):
            if local(name) in ROUND_ATTRS and NUM_RE.search(val):
                new = NUM_RE.sub(shrink, val)
                if new != val:
                    el.set(name, new)
                    n += 1
    return n


# ---------------------------------------------------------------- commands

def read_source(path):
    if path == "-":
        return sys.stdin.read()
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError as e:
        die("cannot read %s: %s" % (path, e))


def parse_svg(raw):
    reject_doctype(raw)                 # before extraction, while the DTD is still visible
    src = extract(raw)
    try:
        return ET.fromstring(src)
    except ET.ParseError as e:
        die("the SVG does not parse: %s. Keep the raw reply (--keep-raw) and look at it." % e)


def cmd_build(a):
    if a.size not in SIZES:
        die("--size must be one of %s (got %d)" % ("/".join(map(str, SIZES)), a.size))
    if not a.still and not 0 < a.duration <= MAX_DURATION:
        die("--duration must be >0 and <=%.0fs (got %.3f)" % (MAX_DURATION, a.duration))
    bg = parse_color(a.bg) if a.bg else None

    ET.register_namespace("", SVG_NS)
    ET.register_namespace("xlink", XLINK_NS)
    root = parse_svg(read_source(a.source))

    removed = sanitize(root, allow_raster=a.allow_raster)
    if removed:
        warn("stripped unsafe or external content: %s" % ", ".join(sorted(set(removed))))

    vb = normalize_root(root, a.size)
    bg_removed = apply_background(root, vb, bg)

    if a.still:
        stripped = strip_animation(root)
        note = "still"
        if stripped:
            warn("removed %d animation element(s) for --still" % stripped)
    else:
        anims = anim_elements(root)
        if not anims and not has_css_animation(root):
            die("no animation in the SVG, and --still was not given. Regenerate, or "
                "pass --still if a static image is what you want.")
        factor = retime(anims, a.duration) if anims else None
        if anims and factor is None:
            warn("no usable dur= on any animation; leaving the timing alone")
        set_loop(root, anims, a.loop)
        if not anims:
            warn("animation is CSS-only: iteration count is enforced, duration is not")
        note = "animated"

    rounded = round_numbers(root, a.round) if a.round >= 0 else 0

    if a.title:
        t = ET.Element("{%s}title" % SVG_NS)
        t.text = a.title
        root.insert(0, t)

    body = ET.tostring(root, encoding="unicode")
    out = '<?xml version="1.0" encoding="UTF-8"?>\n' + body + "\n"
    os.makedirs(os.path.dirname(os.path.abspath(a.out)) or ".", exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as fh:
        fh.write(out)
    print("wrote %s (%dx%d, %s, %s, %d bytes%s)"
          % (a.out, a.size, a.size, note,
             "transparent" if not bg else "background %s" % bg,
             len(out.encode("utf-8")),
             ", %d attrs rounded" % rounded if rounded else ""))
    if bg_removed:
        print("svgpack: removed %d full-canvas background rect(s)" % bg_removed, file=sys.stderr)


def cmd_probe(a):
    src = read_source(a.gif if hasattr(a, "gif") else a.svg)
    root = parse_svg(src)
    anims = anim_elements(root)
    risky = []
    for el in root.iter():
        if local(el.tag) in ("script", "foreignObject"):
            risky.append("<%s>" % local(el.tag))
        for name, val in el.attrib.items():
            if local(name).startswith("on"):
                risky.append("@" + local(name))
            if (local(name) == "href" or name.endswith("}href")) and not val.strip().startswith("#"):
                risky.append("external href")
            if "javascript:" in val.lower():
                risky.append("javascript: url")
    n_el = sum(1 for _ in root.iter())
    print("file        %s" % a.svg)
    print("size        %s x %s" % (root.get("width", "?"), root.get("height", "?")))
    print("viewBox     %s" % root.get("viewBox", "(none)"))
    print("elements    %d" % n_el)
    if anims:
        print("animation   %d SMIL element(s), cycle %.3fs" % (len(anims), cycle_length(anims)))
        counts = sorted({el.get("repeatCount") or el.get("repeatDur") or "once" for el in anims})
        print("loop        %s" % ", ".join(counts))
    elif has_css_animation(root):
        print("animation   CSS only")
        print("loop        %s" % ("infinite" if re.search(
            r"animation-iteration-count\s*:\s*infinite", "".join(st.text or "" for st in css_blocks(root)))
            else "not declared infinite"))
    else:
        print("animation   none (still)")
        print("loop        n/a")
    vb = root.get("viewBox")
    vbn = [float(x) for x in re.split(r"[\s,]+", vb.strip())] if vb else [0, 0, 0, 0]
    bgs = [el for el in root if covers_canvas(el, vbn)]
    print("background  %s" % (("opaque: %s" % bgs[0].get("fill")) if bgs else "transparent"))
    print("bytes       %d" % len(src.encode("utf-8")))
    if risky:
        print("unsafe      %s" % ", ".join(sorted(set(risky))))
        sys.exit(1)
    print("unsafe      none")


def main():
    # Piping output into `head` should not print a traceback.
    if hasattr(signal, "SIGPIPE"):
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    ap = argparse.ArgumentParser(prog="svgpack")
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="sanitize and normalize model output into an SVG")
    b.add_argument("out")
    b.add_argument("source", help="file holding the raw model reply, or - for stdin")
    b.add_argument("--size", type=int, default=32)
    b.add_argument("--duration", type=float, default=1.0)
    b.add_argument("--loop", type=int, default=0, help="0 = forever")
    b.add_argument("--still", action="store_true")
    b.add_argument("--bg", default=None, help="background color; omit for transparent")
    b.add_argument("--round", type=int, default=2, help="decimal places; -1 to leave numbers alone")
    b.add_argument("--allow-raster", action="store_true", help="keep data: image hrefs")
    b.add_argument("--title", default=None)
    b.set_defaults(func=cmd_build)

    p = sub.add_parser("probe", help="report what an SVG actually contains; exits 1 if unsafe")
    p.add_argument("svg")
    p.set_defaults(func=cmd_probe)

    a = ap.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
