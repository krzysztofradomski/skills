# skills

> My own personal agent skills, built for how I work — shared in case they are useful to you too.
> Nothing here is an official or supported product: expect opinionated defaults, and read a skill's
> README before running it. Fork it, strip out what does not fit, keep what does.

Agent skills for [Claude Code](https://claude.com/claude-code) and
[Codex CLI](https://developers.openai.com/codex/cli).

**Built Claude-first.** Claude Code is the primary target: that is where these are designed, used
and tested. Codex CLI is a first-class second — the same `SKILL.md` loads there, every feature is
expected to work, and where the two differ a skill adapts rather than degrades. `delegate`, for
instance, routes code review to whichever vendor you are *not* running inside, so it is genuinely
useful from either side.

## What a skill is

A skill is a folder containing a `SKILL.md`: a description of some capability, plus instructions for
using it. Your agent reads only the descriptions of installed skills. When a request matches one, it
loads that skill's full instructions and follows them.

So a skill is not a plugin you call. It is knowledge the agent picks up when relevant — a workflow
it should follow, a tool it should prefer, a mistake it should avoid. Claude Code and Codex CLI both
read this same format from their own skill directories, so one folder serves both.

## Skills

| Skill | What it does |
|---|---|
| [delegate](delegate/) | Routes work to whichever provider is cheapest for the job — Antigravity and Codex on plan allowance, OpenRouter free models — matching model strength to task difficulty. Generates images for free. |

## Install

### Let your agent do it

Paste this to Claude Code or Codex:

> Install the skills from https://github.com/krzysztofradomski/skills — clone it, then symlink the
> skills into my agent skill directory and any bundled scripts onto my PATH. Show me what you linked.

The agent reads the repo and does the rest. Ask it for just one skill if you do not want all of them.

### One command

```bash
curl -fsSL https://raw.githubusercontent.com/krzysztofradomski/skills/main/install.sh | bash
```

Piping a stranger's script into your shell is a habit worth resisting, so read it first if you
prefer — it is short:

```bash
curl -fsSL https://raw.githubusercontent.com/krzysztofradomski/skills/main/install.sh -o install.sh
less install.sh && bash install.sh
```

It clones to `~/.local/share/agent-skills`, symlinks each skill into `~/.claude/skills` (and
`~/.codex/skills` when Codex is present), and puts bundled scripts on your `PATH`. Re-running it
updates the clone. It never overwrites a real directory — if something is already there under that
name it says so and skips. Pass names to install a subset (`bash install.sh delegate`), and set
`SKILLS_DIR`, `CLAUDE_DIR`, `CODEX_DIR` or `BIN_DIR` to put things elsewhere.

### By hand

Clone the repo wherever you keep code, then symlink the skills you want into your agent's skill
directory. Symlinks rather than copies: edits and `git pull`s take effect immediately instead of
leaving you with a stale duplicate.

```bash
git clone https://github.com/krzysztofradomski/skills.git ~/code/skills
cd ~/code/skills

mkdir -p ~/.claude/skills ~/.codex/skills
ln -s "$PWD/delegate" ~/.claude/skills/delegate    # Claude Code
ln -s "$PWD/delegate" ~/.codex/skills/delegate     # Codex CLI
```

Clone anywhere you like — `$PWD` keeps the commands correct whatever path you chose. Install only
the skills you want; each folder is independent, and installing one directory does not pull in the
rest.

Some skills ship a script. Put it on your `PATH` so both you and the agent can run it by name:

```bash
mkdir -p ~/.local/bin
ln -s "$PWD/delegate/scripts/delegate.sh" ~/.local/bin/delegate.sh
```

If `~/.local/bin` is not already on your `PATH`, add it to your shell profile:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

**Verify it worked.** Start a new agent session — skills load at startup, so an already-running one
will not see it — and type `/delegate` in Claude Code, or ask the agent to list its skills. To
update later, `git pull` in the clone; the symlinks pick it up with nothing to reinstall.

Requirements and configuration differ per skill. Read that skill's own README before first use —
`delegate`, for example, wants API keys for its optional providers and can spend money if you opt in
with a flag.

## Using a skill

You do not need to invoke a skill by name. Describe what you want, and the agent loads the skill
whose description matches — "delegate this to a cheaper model" pulls in `delegate` on its own. Name
it explicitly (`/delegate`) when you want to be certain, or when the phrasing is ambiguous.

## Site

[`site/`](site/) is a single self-contained `index.html`: a landing page built around a real
`delegate` session against a prepared demo repo — reading a file, writing a fix, catching a bug in
that fix through cross-vendor review, and generating an image, all on plan allowance. The transcript
plays out line by line, and a tab bar switches between skills; both are CSS-only, so there is **no
JavaScript** on the page at all. No build step and no dependencies beyond Google Fonts — drop the
folder into Cloudflare Pages (or any static host) as-is.

## Writing a skill

```
skill-name/
├── SKILL.md        # required: YAML frontmatter (name, description) + instructions
├── REFERENCE.md    # optional: detail the agent loads only when it needs it
├── README.md       # optional: for humans — install, requirements, limitations
└── scripts/        # optional: deterministic work better done in code than re-derived
```

Drop a new folder in and `install.sh` picks it up — it treats any directory containing a `SKILL.md`
as installable, with no manifest to update.

The `description` is the only thing the agent sees when deciding whether to load the skill, so it
has to say both what the skill does and when to reach for it. Keep `SKILL.md` short and push detail
into `REFERENCE.md`; everything in `SKILL.md` costs context on every load.

Two things worth stealing from `delegate`: put a guard in code rather than documenting a rule and
hoping the model follows it, and never let a skill spend money without an explicit flag.

## License

MIT — see [LICENSE](LICENSE).
