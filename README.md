# skills

> My own personal agent skills, built for how I work — shared in case they are useful to you too.
> Nothing here is an official or supported product: expect opinionated defaults, and read a skill's
> README before running it. Fork it, strip out what does not fit, keep what does.

Agent skills for [Claude Code](https://claude.com/claude-code) and
[Codex CLI](https://developers.openai.com/codex/cli).

A skill is a folder with a `SKILL.md` — instructions the agent loads when the task matches its
description. Both CLIs read them from their own skill directories, so one folder can serve both.

## Skills

| Skill | What it does |
|---|---|
| [delegate](delegate/) | Routes work to whichever provider is cheapest for the job — Antigravity and Codex on plan allowance, OpenRouter free models — matching model strength to task difficulty. Generates images for free. |

## Install

Each skill is self-contained. Symlink the ones you want into your agent's skill directory, so edits
here take effect immediately rather than drifting from a copy:

```bash
git clone <this-repo> ~/code/skills
ln -s ~/code/skills/delegate ~/.claude/skills/delegate    # Claude Code
ln -s ~/code/skills/delegate ~/.codex/skills/delegate     # Codex CLI
```

Skills that ship scripts want them on your `PATH`:

```bash
ln -s ~/code/skills/delegate/scripts/delegate.sh ~/.local/bin/delegate.sh
```

Then check it loaded — `/delegate` in Claude Code, or ask the agent to list its skills.
Per-skill requirements and configuration live in that skill's own README.

## Writing a skill

```
skill-name/
├── SKILL.md        # required: YAML frontmatter (name, description) + instructions
├── REFERENCE.md    # optional: detail the agent loads only when it needs it
├── README.md       # optional: for humans — install, requirements, limitations
└── scripts/        # optional: deterministic work better done in code than re-derived
```

The `description` is the only thing the agent sees when deciding whether to load the skill, so it
has to say both what the skill does and when to reach for it. Keep `SKILL.md` short and push detail
into `REFERENCE.md`; everything in `SKILL.md` costs context on every load.

Two things worth stealing from `delegate`: put a guard in code rather than documenting a rule and
hoping the model follows it, and never let a skill spend money without an explicit flag.

## License

MIT — see [LICENSE](LICENSE).
