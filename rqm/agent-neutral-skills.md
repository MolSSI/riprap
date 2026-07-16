# Feature: Agent-Neutral Guardrails Skills <!-- rq-8d83394b -->

Guardrails stores each canonical skill implementation and its project-owned customization in an
agent-neutral directory. Agent-specific skill directories contain only the adapters required for
skill discovery and for translating agent-specific conventions.

## Template Layout <!-- rq-8f041d7b -->

- Canonical skill implementations and their supporting files live under
  `.guardrails/skills/<skill-name>/`.
- Each canonical skill reads project-specific extensions from
  `.guardrails/skills/<skill-name>/local.md`.
- Claude discovers thin adapters under `.claude/skills/<skill-name>/SKILL.md`.
- Codex discovers thin adapters under `.agents/skills/<skill-name>/SKILL.md`.
- Both adapters delegate to the same canonical implementation and translate only conventions that
  differ between their agents.
- Canonical implementations and supporting files are template-owned.
- Copier creates each `local.md` once and preserves it during later template updates.
- Generated projects contain no canonical skill implementations or `local.md` files under
  `.claude/skills` or `.agents/skills`.

## Planning Clarification <!-- rq-43c9b2b8 -->

- The planning skill identifies unresolved decisions that would materially change requirements,
  implementation, compatibility, or user-visible behavior.
- The skill asks the user about each material ambiguity before writing requirements, batching
  related questions where practical.
- The skill does not ask ceremonial questions when the request and project context already resolve
  all material decisions; it records any non-obvious assumptions and proceeds.
- In Codex Plan mode, the adapter directs the skill to use structured user input. In other Codex
  modes, it directs the skill to ask a concise textual question only when clarification is required.

## Gherkin Scenarios <!-- rq-637415e2 -->

```gherkin
Feature: Agent-neutral Guardrails skills

  @rq-217d25aa
  Scenario: A generated project uses the agent-neutral skill layout
    Given the Guardrails template is rendered with Copier
    When the generated project is inspected
    Then every supported skill has one canonical implementation under ".guardrails/skills"
    And Claude and Codex each have a discovery adapter for every supported skill
    And canonical supporting resources are not duplicated in either agent-specific directory

  @rq-df3907ad
  Scenario: Skill customization survives a Copier update
    Given a project was generated from an earlier Guardrails template revision
    And a user has modified ".guardrails/skills/gr-plan/local.md"
    And a later template revision changes the canonical gr-plan implementation
    When "copier update" applies the later revision to the project
    Then the user's local customization is unchanged
    And the generated canonical gr-plan implementation contains the later template revision
```
