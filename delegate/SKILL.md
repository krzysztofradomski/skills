---
name: delegate
description: Delegate work from the current Claude Code or Codex session to other providers - Antigravity CLI, Codex CLI, and OpenRouter free models - using existing plan allowances without switching IDEs or chat apps, and picking a model that matches the task's difficulty and cost. Use when the user says delegate, orchestrate, use another provider, use a cheaper model, save tokens, run a code review, or asks for sub-agents. Also generates images for free.
---

# Delegate

You are the **orchestrator** in the user's current agent: you own requirements, architecture and
integration while delegates from other providers do work you have already specified. Keep the user
in this session and bring the delegated result back here. Never accept a delegate's output
unreviewed.

## Quick start

```bash
delegate.sh providers [--check]                # who's up; --check validates the key
delegate.sh read  "<prompt>" [dir]             # read/search/summarize   (Gemini)
delegate.sh code  "<prompt>" [dir] [--write]   # ordinary implementation (Claude Sonnet)
delegate.sh hard  "<prompt>" [dir] [--write]   # subtle / cross-cutting  (Claude Opus)
delegate.sh cheap "<prompt>" [dir]             # trivial one-liners      (Gemini Flash low)
delegate.sh review [dir] [--uncommitted|--base <branch>] [--by claude|codex]  # cross-vendor review
delegate.sh codex "<prompt>" [dir] [--write]   # the only delegate that can run shell/tests
delegate.sh or    "<prompt>" [model]           # free frontier model, best-first
delegate.sh image "<prompt>" out.png [--paid]  # free; --paid to allow spending
delegate.sh skills [agy|codex]                 # what that provider actually has
```

The delegating verbs (`read` `code` `hard` `cheap` `codex` `or`) also take `--skill NAME` or
`--force-skill NAME`; `review` does not. Run `providers` first.
(`delegate.sh` is symlinked into `~/.local/bin`; source is in this skill's `scripts/`.)

## Match the model to the difficulty

Picking by habit is the failure mode — everything to the cheap model, or everything to the strong
one. Decide on the work:

| The work is… | Use |
|---|---|
| Subtle, cross-cutting, hard to reverse, security-sensitive | `hard` |
| A bounded change you could describe to a competent stranger | `code` |
| Reading, searching, tracing a call graph across many files | `read` |
| Mechanical and checkable at a glance — rename, regex, format | `cheap` |

If a result looks confused, rerun a tier up rather than patching bad output yourself; retries cost
plan allowance, not tokens.

**When two tiers both fit, split the work.** Hard *and* needs tests is common: plan it with `hard`
read-only, then execute with `codex --write`, the only delegate that can run a build or test suite.

## Provider order

1. **Antigravity** — plan allowance, real file tools. Claude models reason best about code; Gemini
   is faster with the context for whole-tree reads. That split is what the verbs encode.
2. **OpenRouter free** — when Antigravity is down, or one-shot text needing no repo context.
3. **Codex** — adversarial review, and anything that must actually run commands.

`delegate.sh review` puts a **different vendor's** model against work you just accepted, because
reviewing code with the model that wrote it mostly confirms it. The reviewer is chosen from whichever
CLI you are running inside: in Claude Code it runs `codex review` (which also gets shell access to
run tests); inside Codex it reviews with Claude Opus via Antigravity. Override with
`--by claude|codex`. Use it after any non-trivial change, including your own.

## Delegating well

A delegate has none of your context. Give paths, the exact change, the acceptance check, and "do not
touch anything else".

Bad: `fix the tests`
Good: `In /path/repo, src/board.ts:42 throws on empty input. Add a guard returning []. Run
npm test -- board. Change nothing else.`

Read the diff and rerun the checks yourself. Verbs are read-only without `--write`; with it, the
script verifies the workspace actually changed, retries once on a model that writes reliably, and
fails loudly if nothing changed.

Skills are **not** picked up reliably on their own — use `--force-skill` when a skill matters, and
expect `--skill` to be ignored. Images have two free paths before anything paid; without `--paid`
the command fails rather than quietly spending, so ask before passing it.

Per-tier models are overridable (`M_HARD` `M_CODE` `M_READ` `M_CHEAP` `M_WRITE`); `providers` prints
the current wiring.

See [REFERENCE.md](REFERENCE.md) for provider quirks, skill mechanics, free-model ranking, and the
reasons behind each guard.
