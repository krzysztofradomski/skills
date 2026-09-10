# tests

224 assertions across five suites. No test framework, no network, no provider
calls, no money: [`lib.sh`](lib.sh) is forty lines of shell, and every provider
-- delegate itself, and the agy/codex/openrouter it talks to -- is faked.

```bash
bash tests/run.sh                 # everything available
bash tests/run.sh svg gif         # a subset
bash tests/run.sh --no-render     # skip the browser suite
```

| Suite | Needs | Covers |
|---|---|---|
| [`test_delegate.sh`](test_delegate.sh) | `jq` | provider detection, tier routing, the write-verification guard and its retry, skill application, openrouter's free-model fallback, free-before-paid images |
| [`test_svg.sh`](test_svg.sh) | `python3` | extraction, the sanitizer, geometry, retiming, frame sequences, generation and the retry loop |
| [`test_gif.sh`](test_gif.sh) | `python3` + Pillow | sizes, matte keying, delay quantization, looping, sheet slicing, generation |
| [`test_install.sh`](test_install.sh) | a git clone | linking, subsets, idempotency, refusing to clobber |
| [`test_render.py`](test_render.py) | Playwright + Chromium | whether the output actually moves, in a real browser |

Missing dependencies **skip**, they do not fail: the shell suites run anywhere
with `python3`, and the render suite bows out cleanly when Playwright or a
Chromium is not installed.

## How generation is tested without a provider

`make_fake_delegate` writes a stand-in `delegate.sh` onto `PATH` that replays
canned replies in order and records the prompt and tier it was handed. That makes
the interesting paths testable and deterministic:

- the **retry loop** — a first reply that is deliberately static, so the animated
  default rejects it, escalates `code` → `hard`, and hands the model back its own
  error;
- the **prompts** — that the CSS default asks for CSS, `--smil` asks for SMIL, and
  the gif prompt asks for one sprite sheet and the matte it is about to key out;
- **giving up** — two bad replies in a row ending in advice rather than a stack
  trace.

The `fixtures/svg/` replies are written the way models actually answer: wrapped in
prose, fenced, missing an `xmlns`, or carrying a `<script>` and an external
`<image>`. [`hostile.txt`](fixtures/svg/hostile.txt) is the sanitizer's whole job
in one file.

## Things these tests already caught

- **`--still` left CSS animations running.** The declaration was only stripped
  when it began a line, so `fill:…; animation:…` in one rule survived a file that
  had just been declared static.
- **The GIF installer regression**: `available` returned 1 whenever the last
  directory had no `SKILL.md`, and `set -e` killed an argument-less
  `bash install.sh` before it linked anything.
- **The SVG loop period** was `begin + dur` rather than the duration, which made
  a staggered loader run faster than asked. That one was found while writing the
  CSS path against the same fixture, and the assertion now pins both techniques.

## Assertions worth reading

The interesting ones are not "it exits 0" — they are the ones that pin behaviour
a refactor would quietly break:

```bash
expect_has "[130, 130, 130, 130, 120, 120, 120, 120]" "spreads an uneven remainder across frames"
file_has "$TMP/t1.svg" 'begin="0.3333s"'  "SMIL: keeps the delay at the same fraction of the loop"
file_has "$TMP/f.svg"  "animation-delay: -0.75s" "and frame 3 by three"
```

And in the render suite, the same file is opened twice — once normally, once with
`reduced_motion="reduce"` — to assert it animates in one and holds still in the
other. The `<img>` case is checked too and reported as a note rather than a
failure, because a browser ignoring the host setting there is the documented
limitation, not our bug.
