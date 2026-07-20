# Feature: Agent Permission Defaults <!-- rq-0996aefa -->

Riprap ships a least-privilege permission configuration for each supported agent that provides one.
The defaults pre-approve the commands Riprap itself invokes and the routine verification commands of
the project's language, so a generated project is usable without prompting for the work Riprap
expects. Anything broader is the project's decision and is recorded where a template update cannot
disturb it.

## Default Allow Scope <!-- rq-8ba9f1d4 -->

- The shipped configuration pre-approves every command that a Riprap skill invokes, so a project
  can use the skills Riprap ships without approving Riprap's own tooling.
- It pre-approves the routine build, test, and lint commands of the project's language.
- It pre-approves no general language interpreter, no package installer, and no general-purpose
  shell. A project that wants one grants it deliberately.
- Each language variant grants named commands rather than an interpreter, so the breadth of the
  default is the same whichever language a project selects.
- Every entry uses a permission rule type that the agent enforces. A rule the agent ignores is not
  a default; it is a comment that reads like one.
- Riprap ships no permission configuration for a supported agent that provides no permission
  mechanism. The development container described in `development-container.md` remains the boundary
  in that case.

## Credential-Path Denials <!-- rq-6429f635 -->

- The shipped configuration denies reading the project environment file and the agent credential
  files that could appear in a workspace.
- Denials are expressed as the agent's deny rules, which the agent evaluates ahead of any allow
  rule and enforces itself.
- These denials narrow accidental exposure of credentials to agent context. They are not a
  containment boundary: a permitted shell command can still read a denied path. Keeping credentials
  out of the workspace and out of version control belongs to `agent-credential-isolation.md`, and
  bounding what a command can reach belongs to `development-container.md`.

## Project Additions <!-- rq-dc554228 -->

- A project records its own permissions in the agent's user-local settings file, which the agent
  merges with the shipped configuration rather than replacing it.
- The user-local settings file is excluded from version control, so one contributor's approvals do
  not become the project's policy.
- The shipped configuration is managed. A project does not edit it to add a permission, and a
  template update revises it without disturbing the project's own additions.

## Container Enforcement <!-- rq-2430a9f0 -->

- Every supported agent refuses to begin an AI response when a generated project is opened outside
  Riprap's development container.
- Claude and Codex use their supported project hook mechanisms. OpenCode uses a managed,
  dependency-free project plugin that performs the same container check before an interactive or
  non-interactive request can produce an AI response.
- The OpenCode check applies to the interactive terminal interface, `opencode run`, resumed
  sessions, and every other OpenCode entry point that the generated-project documentation supports.
- A prose instruction, executable wrapper that exists only in the container, or check that runs
  only before agent tool calls does not satisfy this boundary because a host-installed OpenCode
  process could already have sent workspace content to a model.
- Failure is closed and actionable: the request produces no AI response and identifies the Riprap
  launcher that should be used.

## Feature Interface <!-- rq-f75ca93e -->

- `.claude/settings.json`
  - Carries the shipped allow rules, the credential-path deny rules, and the container-check hook.
    Managed, and updated through `copier update`.
- `.claude/settings.local.json`
  - The documented place for a project's own permissions. Not rendered by the template, excluded
    from version control, and merged with the shipped configuration by the agent.
- `opencode.json`
  - Carries managed OpenCode permission defaults, disables OpenCode's automatic updater, and leaves
    provider and model selection to the user. Managed, and updated through `copier update`.
- `.opencode/plugins/check-container.js`
  - Runs the canonical managed container check before OpenCode can produce an AI response. Managed,
    dependency-free, and updated through `copier update`.
- OpenCode user configuration within its project-scoped state volume
  - Is the documented place for provider, model, and personal permission choices. It is not rendered
    by the template and is not replaced by `copier update`.

## Gherkin Scenarios <!-- rq-a71e12c8 -->

```gherkin
Feature: Ship least-privilege agent permission defaults

  @rq-f40bdc52
  Scenario: Shipped defaults cover the commands Riprap's own skills invoke
    Given a project is rendered from the Riprap template
    When the shipped permission configuration is inspected
    Then every command that a Riprap skill invokes is pre-approved

  @rq-93f9b6ff
  Scenario: Shipped defaults grant no interpreter, installer, or shell
    Given a project is rendered from the Riprap template
    When the shipped allow rules are inspected
    Then no rule grants a general language interpreter
    And no rule grants a package installer
    And no rule grants a general-purpose shell

  @rq-38ddfa1e
  Scenario: Language variants grant comparable breadth
    Given a project is rendered for each supported language
    When the shipped allow rules of each are compared
    Then each grants named build, test, and lint commands only

  @rq-19afb5fd
  Scenario: Credential-shaped reads are denied
    Given a project is rendered from the Riprap template
    When the shipped deny rules are inspected
    Then reading the project environment file is denied
    And reading each agent credential file is denied

  @rq-53993832
  Scenario: OpenCode receives equivalent permission defaults
    Given a project is rendered from the Riprap template
    When the managed OpenCode configuration is inspected
    Then every command that a Riprap skill invokes is pre-approved
    And the project's language build, test, and lint commands are pre-approved
    And no general interpreter, package installer, or shell is pre-approved
    And project environment and agent credential paths are denied
    And OpenCode automatic updates are disabled

  @rq-f2003da4
  Scenario: OpenCode blocks interactive use outside the development container
    Given a generated project is opened by a host-installed OpenCode terminal interface
    And the Riprap container marker is absent
    When the user submits a prompt
    Then the container check rejects the request before workspace content is sent to a model
    And OpenCode produces no AI response
    And the diagnostic identifies the Riprap launcher

  @rq-20e684a9
  Scenario: OpenCode blocks non-interactive use outside the development container
    Given a generated project is opened by host-installed OpenCode
    And the Riprap container marker is absent
    When `opencode run` submits a prompt
    Then the container check rejects the request before workspace content is sent to a model
    And OpenCode produces no AI response
    And the command exits nonzero with a diagnostic identifying the Riprap launcher

  @rq-2a2787e3
  Scenario: OpenCode accepts requests inside the development container
    Given a generated project is opened by OpenCode inside Riprap's development container
    When an interactive or non-interactive prompt is submitted
    Then the container check succeeds
    And OpenCode may process the request normally

  @rq-f928505b
  Scenario: A project's own permissions are not version-controlled
    Given a project is rendered from the Riprap template
    When the agent user-local settings file is evaluated against the project's ignore rules
    Then it is ignored

  @rq-1016a30a
  Scenario: A project's own permissions survive a template update
    Given a project has recorded a permission in the agent user-local settings file
    And a later template revision changes the shipped permission configuration
    When "copier update" applies the later revision
    Then the project's recorded permission is unchanged
    And the shipped configuration contains the later revision
```
