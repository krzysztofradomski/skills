# svg

Small SVG icons, for Claude Code (primary) and Codex CLI. Looping SMIL animation by default, or a
single still image with `--still`. Square, 16/32/64/128 px, transparent or on a solid background,
loops up to three seconds.

The sibling of [`gif`](../gif/), with one important difference: an SVG is *code*, so it comes from a
[`delegate`](../delegate/) **text** tier rather than an image model. That means it runs on plan
allowance rather than the small daily image quota, and you get something you can read, diff, restyle
and hand to a designer.

## Requirements

- `python3` — standard library only. No Pillow, no ImageMagick, no network.
- The [`delegate`](../delegate/) skill on your `PATH` — only to *generate*. `build`, `probe` and
  `preview` work without it.
- Optional, for `preview`: `rsvg-convert`, ImageMagick, Inkscape, or any Chrome/Chromium.
- `bash`. Written for bash 3.2 (macOS) as well as newer bash.

Check with `svg.sh check`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/krzysztofradomski/skills/main/install.sh | bash -s delegate svg
```

Or by hand, from the root of your clone of
[the skills repo](https://github.com/krzysztofradomski/skills):

```bash
ln -s "$PWD/svg" ~/.claude/skills/svg                  # Claude Code
ln -s "$PWD/svg" ~/.codex/skills/svg                   # optional: Codex CLI
ln -s "$PWD/svg/scripts/svg.sh" ~/.local/bin/          # both, plus your own shell
```

Only `svg.sh` goes on your `PATH`; `svgpack.py` sits next to it and is found through the symlink.

## Use

```bash
svg.sh make "a ringing notification bell" bell.svg     # 32px, transparent, 1s loop, forever
svg.sh still "a bell" bell-static.svg                  # no animation at all
svg.sh make "a loading spinner" spin.svg --size 64 --duration 1.5
svg.sh build out.svg my-reply.txt --still              # normalize source you already have
svg.sh probe out.svg                                   # also a lint: exits 1 on anything unsafe
svg.sh preview out.svg out.png                         # rasterize frame 0 and look at it
```

Or ask your agent for "a 64px transparent looping svg spinner" and let it load the skill.

## What it refuses to pass through

Model-written SVG is untrusted input, and an SVG can execute. Every build strips `<script>`,
`<foreignObject>`, `on*` handlers, `javascript:` URLs, external and `data:` references and CSS
`@import`, and refuses any file carrying a `DOCTYPE` or `ENTITY` declaration. `svg.sh probe` reports
the same set for a file from anywhere and exits nonzero if it finds one, so you can point it at SVGs
you did not generate.

That is a sanitizer for *this* pipeline's output, not a hardened gateway for arbitrary hostile
uploads — treat it as a seatbelt, not a firewall.

## Limitations

- **Drawing quality is the model's.** At 16–32px you want one strong shape; ornate subjects fail
  however clean the source is.
- **SMIL only for exact timing.** If a model returns CSS `@keyframes` anyway, the loop is forced
  infinite but the duration is not rewritten, and the run says so.
- **Frame-0 previews.** `preview` shows the drawing, not the motion; open the file in a browser to
  watch it.
- Developed on Linux; the script avoids GNU-only flags and `readlink -f` so it works on macOS bash
  3.2, but macOS is less exercised.

Full behaviour and flags: [SKILL.md](SKILL.md) and [REFERENCE.md](REFERENCE.md).

MIT, like the rest of the repo.
