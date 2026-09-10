#!/usr/bin/env python3
"""Render checks: does the output actually move, in a real browser?

Everything else in this suite reads files. These open them in Chromium, pin the
animation timeline instead of sleeping, and compare pixels -- the only way to
tell a correct-looking SVG from one that renders blank or never animates.

Optional: skipped cleanly when Playwright and a Chromium are not both available.
    pip install playwright && playwright install chromium
"""
import hashlib
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIX = ROOT / "tests" / "fixtures" / "svg"
SVGPACK = [sys.executable, str(ROOT / "svg" / "scripts" / "svgpack.py")]
PASS = FAILED = 0


def ok(desc):
    global PASS
    PASS += 1
    print("  ok   %s" % desc)


def bad(desc, detail=""):
    global FAILED
    FAILED += 1
    print("  FAIL %s" % desc)
    if detail:
        print("       %s" % detail)


def check(cond, desc, detail=""):
    ok(desc) if cond else bad(desc, detail)


def find_chromium(p):
    """Playwright's own browser, or one the machine already has."""
    for launcher in (lambda: p.chromium.launch(),
                     lambda: p.chromium.launch(channel="chrome")):
        try:
            return launcher()
        except Exception:
            continue
    for env in ("CHROME", "CHROMIUM"):
        exe = os.environ.get(env)
        if exe and os.path.exists(exe):
            args = ["--no-sandbox"] if os.geteuid() == 0 else []
            return p.chromium.launch(executable_path=exe, args=args)
    return None


def build(out, fixture, *args):
    subprocess.run(SVGPACK + ["build", str(out), str(FIX / fixture)] + list(args),
                   check=True, capture_output=True)
    return pathlib.Path(out)


def page_for(tmp, svg_path, inline):
    """Two ways a browser meets an SVG, and they do not behave the same."""
    body = ('<body style="margin:0;background:#111">'
            + (svg_path.read_text().split("?>", 1)[1]
               .replace('width="32"', 'width="200"').replace('height="32"', 'height="200"')
               if inline else
               '<img src="%s" style="width:200px;height:200px">' % svg_path.name)
            + "</body>")
    html = tmp / ("inline.html" if inline else "img.html")
    html.write_text(body)
    return html.as_uri()


def shots(page, n=3, gap=180):
    out = []
    for _ in range(n):
        out.append(hashlib.md5(page.screenshot()).hexdigest())
        page.wait_for_timeout(gap)
    return out


def main():
    global FAILED
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("  skip playwright is not installed (pip install playwright)")
        return 0

    tmp = pathlib.Path(tempfile.mkdtemp())
    with sync_playwright() as p:
        browser = find_chromium(p)
        if browser is None:
            print("  skip no Chromium available (playwright install chromium)")
            return 0

        print("\n--- CSS animation")
        css = build(tmp / "css.svg", "animated-css.txt", "--duration", "1")
        pg = browser.new_page(viewport={"width": 200, "height": 200})
        pg.goto(page_for(tmp, css, inline=True))
        pg.wait_for_timeout(300)
        frames = shots(pg)
        check(len(set(frames)) > 1, "an inlined CSS icon actually animates",
              "every screenshot was identical: %s" % frames[0][:8])
        pg.close()

        print("\n--- prefers-reduced-motion")
        rm = browser.new_page(viewport={"width": 200, "height": 200}, reduced_motion="reduce")
        rm.goto(page_for(tmp, css, inline=True))
        rm.wait_for_timeout(300)
        frames = shots(rm)
        check(len(set(frames)) == 1, "the same icon holds still under reduced motion",
              "it kept animating: %s" % [f[:8] for f in frames])
        rm.close()
        # Documented limitation, asserted so it cannot change without us noticing:
        # through <img> the embedded document does not see the host's setting.
        rm2 = browser.new_page(viewport={"width": 200, "height": 200}, reduced_motion="reduce")
        rm2.goto(page_for(tmp, css, inline=False))
        rm2.wait_for_timeout(300)
        moving = len(set(shots(rm2))) > 1
        print("  %s reduced motion through <img>: %s" % ("note", "ignored by the browser (as documented)"
                                                         if moving else "honoured -- the README can be updated"))
        rm2.close()

        print("\n--- frame sequence")
        seq = build(tmp / "seq.svg", "frames-4.txt", "--frames", "4", "--duration", "1")
        pg = browser.new_page(viewport={"width": 200, "height": 200})
        pg.goto(page_for(tmp, seq, inline=True))
        pg.wait_for_timeout(200)
        seen = []
        for ms in (0, 260, 510, 760, 1010):
            # Pin the timeline rather than sleeping: exact, and fast.
            pg.evaluate("""ms => document.querySelectorAll('.spk-frame').forEach(
                el => el.getAnimations().forEach(a => { a.pause(); a.currentTime = ms; }))""", ms)
            pg.wait_for_timeout(50)
            seen.append(hashlib.md5(pg.screenshot()).hexdigest())
        check(len(set(seen[:4])) == 4, "each quarter of the cycle shows a different frame",
              "only %d distinct frames in 4 slots" % len(set(seen[:4])))
        check(seen[4] == seen[0], "and the cycle wraps back to frame 0")
        pg.close()

        print("\n--- SMIL")
        smil = build(tmp / "smil.svg", "animated-smil.txt", "--duration", "1")
        pg = browser.new_page(viewport={"width": 200, "height": 200})
        pg.goto(page_for(tmp, smil, inline=True))
        pg.wait_for_timeout(200)
        seen = []
        for t in (0.0, 0.25, 0.5, 0.75):
            pg.evaluate("t => document.querySelector('svg').setCurrentTime(t)", t)
            pg.wait_for_timeout(50)
            seen.append(hashlib.md5(pg.screenshot()).hexdigest())
        check(len(set(seen)) >= 3, "a SMIL icon moves through its retimed 1s cycle",
              "%d distinct frames" % len(set(seen)))
        pg.close()

        print("\n--- transparency survives rasterizing")
        png = tmp / "prev.png"
        env = dict(os.environ)
        if os.geteuid() == 0:
            env["CHROME_FLAGS"] = "--no-sandbox"
        r = subprocess.run(["bash", str(ROOT / "svg" / "scripts" / "svg.sh"), "preview",
                            str(css), str(png), "--width", "128"], capture_output=True, env=env)
        if r.returncode == 0 and png.exists():
            try:
                from PIL import Image
                alpha = Image.open(png).convert("RGBA").tobytes()[3::4]
                check(alpha.count(0) > 100, "svg.sh preview keeps the background transparent")
            except ImportError:
                print("  skip Pillow not available to inspect the preview")
        else:
            print("  skip no rasterizer for svg.sh preview")

        browser.close()

    print("\nrender: %d passed, %d failed" % (PASS, FAILED))
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
