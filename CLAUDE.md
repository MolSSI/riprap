# Project Philosophy
- Prefer standard idioms
- Avoid anti-patterns
- Avoid security vulnerabilities
- Do not assume happy paths
- Prefer composition over inheritance
- Prefer structures of arrays over arrays of structures
- Be hesitant to introduce dependencies for small tasks

# Architecture
- See @docs/architecture.md for system design

# Development
- The skills under `.claude/skills/` are generated copies of the Jinja-templated skills in `template/.claude/skills/` (rendered with `language=rust`). Never edit them directly: edit the template versions, then run `scripts/check-skill-sync.sh --fix` to regenerate the dev copies.
