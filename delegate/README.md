# delegate

An orchestrator skill for Claude Code and Codex CLI. It pushes work down to whichever provider is
cheapest for the job — matching model strength to task difficulty — and keeps paid APIs behind an
explicit opt-in.

| Provider | Auth | Used for |
|---|---|---|
| Antigravity CLI (`agy`) | plan allowance | default: reading, coding, images |
| Codex CLI | ChatGPT plan | adversarial review, anything needing shell/tests, images |
| OpenRouter | API key | free frontier models for one-shot text; paid images as last resort |
| Google AI Studio | API key | optional; free tier has **zero** image quota |

Antigravity and Codex bill against a subscription, not per-token, so most work costs nothing extra.

## Requirements

- `bash`, `curl`, `jq`, `git`
- At least one of: [Antigravity CLI](https://antigravity.google), [Codex CLI](https://developers.openai.com/codex/cli)
- Optional: `sips` (macOS), `magick`, or `convert` for PNG conversion
- Developed and tested on macOS (bash 3.2). Linux paths use GNU `stat`/`base64` fallbacks but are
  untested.

## Install

From the root of your clone of [the skills repo](https://github.com/krzysztofradomski/skills):

```bash
ln -s "$PWD/delegate" ~/.claude/skills/delegate                 # Claude Code
ln -s "$PWD/delegate" ~/.codex/skills/delegate                  # optional: Codex CLI
ln -s "$PWD/delegate/scripts/delegate.sh" ~/.local/bin/         # put the script on PATH
delegate.sh providers
```

`providers` prints which backends it found and which models each tier is wired to. It needs no keys
— Antigravity and Codex authenticate through their own CLIs, so if either is installed and logged
in, you can start delegating immediately.

API keys are optional and only unlock OpenRouter's free models and the paid image fallback. They are
read from files so they never appear in argv or shell history:

```bash
mkdir -p ~/.config/openrouter
printf 'OpenRouter key: '; read -rs k; echo
printf '%s' "$k" > ~/.config/openrouter/key; chmod 600 ~/.config/openrouter/key; unset k
```

`$OPENROUTER_API_KEY` and `$GEMINI_API_KEY` (or `~/.config/google-ai/key`) work too.
Verify with `delegate.sh providers --check`, which exits nonzero if a key is rejected.

## Usage

In an agent session you rarely call this directly — say "delegate this to a cheaper model" or
"review my changes" and the agent picks the right verb. Run it yourself when you want a specific
model, or to check what is available. Each verb targets a tier: `read` and `cheap` for fast Gemini
work, `code` and `hard` for Claude reasoning, `codex` for anything that must run tests.

See [SKILL.md](SKILL.md) for routing guidance and [REFERENCE.md](REFERENCE.md) for provider quirks.

```bash
delegate.sh read  "Which files define the auth middleware?" ~/code/app
delegate.sh code  "Add a null guard to parse() in src/x.ts" ~/code/app --write
delegate.sh review ~/code/app --base main          # reviewed by the vendor you are NOT running in
delegate.sh image "a flat blue key icon on white" icon.png
```

## Design notes

Two rules earned through failures, both enforced in code rather than documented and hoped for:

- **A delegate reporting success is a claim, not evidence.** `--write` verifies the workspace
  actually changed; some models' write tools are confined to their own artifact directory and will
  report "Done!" having touched nothing.
- **Nothing spends money silently.** Two free image paths run before any paid one, and the paid path
  requires `--paid`.

## Limitations

- Antigravity cannot run shell commands non-interactively, so its prompts are steered onto file
  tools. Work needing a build or test suite goes to `codex --write`.
- `--skill NAME` is a hint that delegates frequently ignore; `--force-skill NAME` is deterministic.
- Image generation on a plan allowance has a finite daily quota; when it runs out the chain falls
  through to the next free provider.

## License

MIT
