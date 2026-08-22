# Delegate — reference

Details behind [SKILL.md](SKILL.md). Read when a provider misbehaves or a flag needs explaining.

## Why each guard exists

Every rule below came from an observed failure, not a guess.

**`--write` is verified.** Some models' write tool is hard-confined to their own artifact directory,
so they report "Done!" having touched nothing in your workspace. `claude-sonnet-4-6` does this
intermittently regardless of prompt wording. Both Antigravity and Codex check that the workspace
actually changed; the check uses directory mtime, so a deletion-only change counts. On Antigravity a
failed write retries once with `$M_WRITE` (default `gemini-3.1-pro-high`, a model that writes
reliably) and says so on stderr; if that also changes nothing the command fails, pointing at
`codex --write`.

**Antigravity cannot run shell non-interactively.** Nothing can approve the permission prompt, so
the first command the agent reaches for kills the run. Every Antigravity prompt is steered onto file
tools. Anything needing a build or test suite goes to `codex --write`.

**`--add-dir` is mandatory.** Without it the agent has no workspace and its own permission check
denies reading files in its cwd.

**Keys never enter argv.** `curl -K` reads them from a 0600 file instead, so `ps` cannot show them.

## Cross-vendor review

`review` detects its host from the environment (`CODEX_SESSION_ID` for Codex,
`CLAUDE_CODE_ENTRYPOINT`/`CLAUDECODE` for Claude Code) and picks the other vendor, defaulting to
Codex when it cannot tell. `--by` forces one.

The two reviewers are not equivalent. `codex review` runs in the repo with shell access, so it can
execute tests while reviewing. The Claude reviewer goes through Antigravity, which cannot run shell
non-interactively, so the script hands it the diff instead (`git diff HEAD` plus untracked files, or
`base...HEAD` with `--base`) and it reviews by reading. Diffs over 200KB are refused rather than
truncated silently.

The standalone `claude` CLI is *not* used, even when installed: on this machine it reported
`OAuth session expired`. Antigravity already serves Claude Opus on plan allowance, so it needs no
separate login.

## Skills

Delegates do not reliably reach for a skill unprompted. Codex sometimes does; Antigravity did not,
across four runs, even when the prompt used the skill's own documented trigger words, on both a weak
and a strong model.

- `--skill NAME` — suggest. Treat as a hint that may do nothing.
- `--force-skill NAME` — enforce, by slash-invoking. Deterministic on both CLIs.

Skill sets barely overlap: `delegate` is installed for Codex, not Antigravity; `caveman` the
reverse. The script validates the name against the provider that will run it and fails fast.
`delegate.sh skills [agy|codex]` lists what each has. OpenRouter has no skill system, so `--skill`
inlines the SKILL.md text from `~/.claude/skills/` into the prompt (capped at 20KB).

## Free models

`or` selects on price (`prompt == 0 && completion == 0`), not the `:free` id suffix — that suffix
misses `stealth/*`, the cloaked frontier models, which rank first. Ranking is stealth, then known
strong families, then context length; selecting purely by context once put hard work on a small
fast model with a large window.

Shared free pools return 429 constantly, so `or` walks the top four and returns the first that
answers. Pinning a model as the third argument disables that fallback: you get that model or a real
error, including the provider's own `metadata.raw` text.

## Images

Two free paths on plan allowance run before anything paid:

1. **Antigravity** `generate_image`. Writes a JPEG into its own artifact dir and names the path only
   in prose, so the script takes the newest image produced since the run started and `sips`-converts
   to PNG when the target ends in `.png`. If conversion fails it keeps the true extension rather
   than putting JPEG bytes behind a `.png` name.
2. **Codex** `/imagegen`. Its built-in `image_gen` tool needs no API key. The output must be newer
   than the run marker, so a stale file already at that path cannot pass as a fresh success.

Image generation on plan allowance has a **finite daily quota**: Antigravity returns
`429 RESOURCE_EXHAUSTED` with a reset time once it is spent, and the chain falls through to Codex.
That is normal, not a failure. Paid providers are opt-in via `--paid`. AI Studio's free tier grants **zero** image quota — every
image model returns `RESOURCE_EXHAUSTED` with `limit: 0` until billing is enabled — and OpenRouter
spends real credit. A run printing `free` cost nothing.

## Models

`providers` prints the wired tiers; `providers --check` validates the OpenRouter key against the API
and exits 1 if rejected. Override tiers with `M_HARD`, `M_CODE`, `M_READ`, `M_CHEAP`, and `M_WRITE` (the writer-capable
model a failed `--write` retries on).
`agy models` lists everything Antigravity offers, including Gemini 3.x, Sonnet and Opus.
