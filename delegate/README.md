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

```bash
ln -s ~/code/skills/delegate ~/.claude/skills/delegate          # Claude Code
ln -s ~/code/skills/delegate ~/.codex/skills/delegate           # optional: Codex CLI
ln -s ~/code/skills/delegate/scripts/delegate.sh ~/.local/bin/  # put the script on PATH
delegate.sh providers
```

Optional API keys, read from files so they never appear in argv or shell history:

```bash
mkdir -p ~/.config/openrouter && read -rs "?OpenRouter key: " k && printf '%s' "$k" > ~/.config/openrouter/key && chmod 600 ~/.config/openrouter/key && unset k
```

`$OPENROUTER_API_KEY` and `$GEMINI_API_KEY` (or `~/.config/google-ai/key`) work too.
Verify with `delegate.sh providers --check`, which exits nonzero if a key is rejected.

## Usage

See [SKILL.md](SKILL.md) for routing guidance and [REFERENCE.md](REFERENCE.md) for provider quirks.

```bash
delegate.sh read  "Which files define the auth middleware?" ~/code/app
delegate.sh code  "Add a null guard to parse() in src/x.ts" ~/code/app --write
delegate.sh review ~/code/app --base main
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
