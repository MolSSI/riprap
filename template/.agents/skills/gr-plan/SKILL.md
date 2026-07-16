---
name: gr-plan
description: Plan or design a feature and write or revise its requirements documentation without implementing it.
---

Read `.claude/skills/gr-plan/SKILL.md` completely and follow it as the authoritative workflow. It
is shared with Claude Code so Guardrails has one maintained implementation of this skill. When
applying it in Codex:

- Treat `$gr-architecture` and `$gr-implement` as the Codex equivalents of `/gr-architecture` and
  `/gr-implement`.
- Read `AGENTS.md` and `rqm/ARCHITECTURE.md` for project guidance when the shared workflow refers
  to `CLAUDE.md` and documents referenced by it.
- Use Codex's available user-input mechanism when the workflow refers to `AskUserQuestion`.
