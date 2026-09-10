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
import urllib.parse
import xml.etree.ElementTree as ET

def linked(path):
    """The path as an OSC 8 hyperlink, so a terminal that supports them opens the file on a
    click. Plain text when stdout is not a terminal, which keeps captured output parsable."""
    if not sys.stdout.isatty():
        return path
    url = "file://" + urllib.parse.quote(os.path.abspath(path))
    return "\033]8;;%s\033\\%s\033]8;;\033\\" % (url, path)

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


# The reduced-motion block this script writes says `animation: none`, which must
# not be mistaken for the file having a CSS animation.
REDUCED_RE = re.compile(r"@media[^{]*prefers-reduced-motion[^{]*\{(?:[^{}]*\{[^{}]*\}\s*)*\}", re.I)


def has_css_animation(root):
    txt = REDUCED_RE.sub("", "".join(st.text or "" for st in css_blocks(root)))
    return bool(re.search(r"@keyframes", txt, re.I)
                or re.search(r"animation(?:-name)?\s*:\s*(?!none\b)[^;}]+", txt, re.I))


# A whole declaration, wherever it sits in the block. Anchoring this to the start
# of a line only stripped `animation:` when it happened to open one, which left a
# running animation in a file that had just been declared still.
ANIM_DECL_RE = re.compile(r"(?<![-\w])(?:animation|transition)(?:-[a-z-]+)?\s*:[^;}]*;?", re.I)
KEYFRAMES_RE = re.compile(r"@(?:-[a-z]+-)?keyframes[^{]*\{(?:[^{}]*\{[^{}]*\}\s*)*\}", re.I)


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
        txt = ANIM_DECL_RE.sub("", KEYFRAMES_RE.sub("", st.text))
        if txt != st.text:
            n += 1
        st.text = txt
    for el in root.iter():
        style = el.get("style")
        if style and ANIM_DECL_RE.search(style):
            el.set("style", ANIM_DECL_RE.sub("", style))
            n += 1
    return n


# A CSS animation declaration: the shorthand (`animation: spin 1.2s linear infinite`)
# or the longhands that carry time. Times must have a unit -- that is what keeps
# `steps(4)` and `cubic-bezier(0.4, 0, 0.2, 1)` from being read as seconds.
CSS_DECL_RE = re.compile(r"(animation(?:-duration|-delay)?)(\s*:\s*)([^;}]*)", re.I)
CSS_TIME_RE = re.compile(r"(-?\d*\.?\d+)(ms|s)\b", re.I)


def _css_seconds(tok, unit):
    v = float(tok)
    return v / 1000.0 if unit.lower() == "ms" else v


def css_sources(root):
    """Everything that can hold a CSS declaration: <style> text and style= attrs."""
    out = [("style-el", st) for st in css_blocks(root)]
    out += [("style-attr", el) for el in root.iter() if el.get("style")]
    return out


def _css_text(kind, node):
    return node.text if kind == "style-el" else node.get("style")


def _css_set(kind, node, text):
    if kind == "style-el":
        node.text = text
    else:
        node.set("style", text)


def css_cycle_length(root):
    """Longest delay+duration across CSS animation declarations.

    In the shorthand the first time is the duration and the second the delay,
    which is the order CSS itself uses; longhands say which they are outright.
    """
    longest = 0.0
    for kind, node in css_sources(root):
        for m in CSS_DECL_RE.finditer(_css_text(kind, node) or ""):
            prop, value = m.group(1).lower(), m.group(3)
            times = [_css_seconds(t, u) for t, u in CSS_TIME_RE.findall(value)]
            if not times:
                continue
            if prop == "animation-duration":
                dur, delay = max(times), 0.0
            elif prop == "animation-delay":
                dur, delay = 0.0, max(t for t in times)
            else:
                dur = times[0]
                delay = times[1] if len(times) > 1 else 0.0
            longest = max(longest, max(delay, 0.0) + dur)
    return longest


def css_retime(root, target):
    """Scale every CSS animation time by one factor, as with SMIL.

    @keyframes offsets are percentages of the cycle, so they need no touching --
    scaling the durations and delays moves the whole choreography together.
    """
    cur = css_cycle_length(root)
    if cur <= 0:
        return None
    factor = target / cur
    if abs(factor - 1.0) < 0.001:
        return 1.0

    def scale_decl(m):
        value = CSS_TIME_RE.sub(
            lambda t: fmt_time(_css_seconds(t.group(1), t.group(2)) * factor), m.group(3))
        return m.group(1) + m.group(2) + value

    for kind, node in css_sources(root):
        txt = _css_text(kind, node)
        if txt:
            _css_set(kind, node, CSS_DECL_RE.sub(scale_decl, txt))
    return factor


def append_css(root, css):
    """Add a rule, reusing the first <style> so the file keeps one."""
    blocks = css_blocks(root) or [st for st in root.iter("{%s}style" % SVG_NS)]
    if blocks:
        blocks[0].text = (blocks[0].text or "") + css
        return
    st = ET.Element("{%s}style" % SVG_NS)
    st.text = css
    root.insert(0, st)


def add_reduced_motion(root, resting_css="* { animation: none !important; }"):
    """Honour prefers-reduced-motion.

    A looping icon is exactly the kind of motion that makes some people ill, and
    an SVG that ignores the setting cannot be fixed from the page when it is used
    in an <img>. SMIL has no way to express this at all; CSS does, so the CSS
    path gets it for free and the packer writes it rather than trusting a model to.
    """
    append_css(root, "\n@media (prefers-reduced-motion: reduce) { %s }\n" % resting_css)


def cycle_length(anims):
    """The loop's period: the longest `dur`.

    Not begin+dur. A repeating animation restarts every `dur`; `begin` only
    offsets when it first starts, so a bar delayed 0.4s inside a 1.2s animation
    is a phase shift within a 1.2s loop, not part of a 1.6s one. Adding them
    made a staggered loader run faster than the duration asked for.
    """
    durs = [parse_time(el.get("dur", "")) for el in anims]
    return max([d for d in durs if d is not None] or [0.0])


def retime(anims, target):
    """Scale every offset so one cycle lasts exactly --duration.

    Rewriting each dur to the target instead would flatten staggered timing into
    a single beat; scaling durations and begins by one factor keeps each element's
    phase as the same fraction of the loop and only changes the tempo.
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


def set_loop_smil(anims, loop):
    """SMIL: an animation with no repeatCount plays once and freezes, which is
    never what 'a looping icon' means."""
    count = "indefinite" if loop == 0 else str(loop)
    for el in anims:
        if not el.get("repeatCount") and not el.get("repeatDur"):
            el.set("repeatCount", count)


def set_loop_css(root, loop):
    """Same for CSS. The rule only reaches elements that already declare an
    animation, so it cannot start anything that was meant to stay still."""
    append_css(root, "\n* { animation-iteration-count: %s; }\n"
               % ("infinite" if loop == 0 else str(loop)))


# ---------------------------------------------------------------- geometry

FRAME_CLASS = "spk-frame"


def frame_groups(root, want):
    """The N drawings the model was asked for, as direct children of the root.

    Anything else at the top level (a background rect, a <style>, a <title>,
    <defs>) is scenery and stays put; only the groups are frames.
    """
    groups = [el for el in root if local(el.tag) == "g"]
    if len(groups) != want:
        die("expected %d frame group(s) as direct <g> children of <svg>, found %d. "
            "Regenerate, or split the file yourself." % (want, len(groups)))
    return groups


def build_frame_animation(root, groups, duration, loop, reduced=True):
    """Show one frame at a time, with timing this script writes.

    Asking a model for per-frame keyframes is asking it to do arithmetic it gets
    wrong; asking it for N drawings is asking it to draw. So the drawings come
    from the model and every number here comes from the code: one animation, a
    step-end hold so frames swap instead of cross-fading, and a negative delay per
    frame that offsets it into its own slot of the cycle.
    """
    n = len(groups)
    slot = 100.0 / n
    count = "infinite" if loop == 0 else str(loop)
    css = ["\n.%s { opacity: 0; animation: %s-cycle %s step-end %s; }"
           % (FRAME_CLASS, FRAME_CLASS, fmt_time(duration), count),
           "@keyframes %s-cycle { 0%% { opacity: 1 } %s%% { opacity: 0 } }"
           % (FRAME_CLASS, ("%.4f" % slot).rstrip("0").rstrip("."))]
    for i, g in enumerate(groups):
        cls = (g.get("class", "") + " " + FRAME_CLASS).strip()
        g.set("class", "%s %s-%d" % (cls, FRAME_CLASS, i))
        if i:
            css.append(".%s-%d { animation-delay: %s; }"
                       % (FRAME_CLASS, i, fmt_time(-duration * i / n)))
    append_css(root, "\n".join(css) + "\n")
    # Reduced motion stops on frame 0 rather than on a blank canvas, which is what
    # the generic `animation: none` would leave behind.
    if reduced:
        add_reduced_motion(root, "* { animation: none !important; } .%s { opacity: 0 } .%s-0 { opacity: 1 }"
                           % (FRAME_CLASS, FRAME_CLASS))
    return n


def write_frame_stills(root, groups, outdir, name):
    """One static SVG per frame: what a renderer that ignores animation can use,
    and what feeds `gif.sh frames` after rasterizing."""
    os.makedirs(outdir, exist_ok=True)
    keep = [el for el in root if local(el.tag) in ("rect", "defs", "title") and el not in groups]
    paths = []
    for i, g in enumerate(groups):
        one = ET.Element("{%s}svg" % SVG_NS, dict(root.attrib))
        for el in keep:
            one.append(el)
        still = ET.fromstring(ET.tostring(g, encoding="unicode"))
        still.set("class", re.sub(r"\s*%s(-\d+)?" % FRAME_CLASS, "", still.get("class", "")).strip())
        if not still.get("class"):
            still.attrib.pop("class", None)
        one.append(still)
        p = os.path.join(outdir, "%s_%02d.svg" % (name, i))
        with open(p, "w", encoding="utf-8") as fh:
            fh.write('<?xml version="1.0" encoding="UTF-8"?>\n'
                     + ET.tostring(one, encoding="unicode") + "\n")
        paths.append(p)
    return paths


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
    if a.still and a.frames:
        die("--still and --frames are opposites; pick one")
    if a.frames and not 2 <= a.frames <= 60:
        die("--frames must be between 2 and 60 (got %d)" % a.frames)
    bg = parse_color(a.bg) if a.bg else None

    ET.register_namespace("", SVG_NS)
    ET.register_namespace("xlink", XLINK_NS)
    root = parse_svg(read_source(a.source))

    removed = sanitize(root, allow_raster=a.allow_raster)
    if removed:
        warn("stripped unsafe or external content: %s" % ", ".join(sorted(set(removed))))

    vb = normalize_root(root, a.size)
    bg_removed = apply_background(root, vb, bg)

    stills = []
    if a.still:
        stripped = strip_animation(root)
        note = "still"
        if stripped:
            warn("removed %d animation element(s) for --still" % stripped)
    elif a.frames:
        # The model drew N moments; every number in the timing comes from here.
        if strip_animation(root):
            warn("removed the model's own animation: in --frames mode the frames "
                 "are static drawings and this script does the timing")
        groups = frame_groups(root, a.frames)
        build_frame_animation(root, groups, a.duration, a.loop, not a.no_reduced_motion)
        if a.keep_frames:
            stills = write_frame_stills(root, groups, a.keep_frames,
                                        os.path.splitext(os.path.basename(a.out))[0])
        note = "%d-frame sequence" % a.frames
    else:
        anims = anim_elements(root)
        css = has_css_animation(root)
        if not anims and not css:
            die("no animation in the SVG, and neither --still nor --frames was given. "
                "Regenerate, or pass --still if a static image is what you want.")
        if anims:
            if retime(anims, a.duration) is None:
                warn("no usable dur= on any SMIL animation; leaving its timing alone")
            set_loop_smil(anims, a.loop)
        if css:
            if css_retime(root, a.duration) is None:
                warn("no usable animation-duration in the CSS; leaving its timing alone")
            set_loop_css(root, a.loop)
        note = "animated (%s)" % ("CSS+SMIL" if anims and css else ("CSS" if css else "SMIL"))
    if not a.still and not a.no_reduced_motion and not a.frames:
        add_reduced_motion(root)

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
          % (linked(a.out), a.size, a.size, note,
             "transparent" if not bg else "background %s" % bg,
             len(out.encode("utf-8")),
             ", %d attrs rounded" % rounded if rounded else ""))
    for p in stills:
        print(p)
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
    css_all = "".join(st.text or "" for st in css_blocks(root))
    n_frames = len([el for el in root.iter() if FRAME_CLASS in (el.get("class") or "").split()])
    kinds, loops = [], []
    if n_frames:
        kinds.append("%d-frame sequence, cycle %.3fs" % (n_frames, css_cycle_length(root)))
    elif has_css_animation(root):
        kinds.append("CSS, cycle %.3fs" % css_cycle_length(root))
    if anims:
        kinds.append("%d SMIL element(s), cycle %.3fs" % (len(anims), cycle_length(anims)))
        loops += sorted({el.get("repeatCount") or el.get("repeatDur") or "once" for el in anims})
    if has_css_animation(root):
        m = re.search(r"animation-iteration-count\s*:\s*([a-z0-9.]+)", css_all, re.I)
        loops.append(m.group(1) if m else
                     ("infinite" if re.search(r"\binfinite\b", css_all) else "not declared infinite"))
    print("animation   %s" % (" + ".join(kinds) if kinds else "none (still)"))
    print("loop        %s" % (", ".join(sorted(set(loops))) if loops else "n/a"))
    print("reduced     %s" % ("honours prefers-reduced-motion"
                              if "prefers-reduced-motion" in css_all else "no media query"))
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
    b.add_argument("--frames", type=int, default=0,
                   help="the input holds N frame groups; this script writes the timing")
    b.add_argument("--keep-frames", default=None, help="also write each frame as a still SVG here")
    b.add_argument("--no-reduced-motion", action="store_true",
                   help="omit the prefers-reduced-motion rule (it is added by default)")
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
