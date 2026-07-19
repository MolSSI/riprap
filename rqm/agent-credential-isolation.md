# Feature: Agent Credential Isolation <!-- rq-60eee682 -->

Riprap keeps Claude and Codex authentication state in project-specific Podman named volumes.
Generated projects never mount a user's host Claude or Codex configuration into the development
container. Layered repository safeguards prevent credentials copied into the workspace from being
committed or pushed accidentally. The version-controlled Git hooks and launch scripts are normalized
so they run on every supported host.

## Project Identity <!-- rq-f3cf5b0e -->

- `.riprap/state/project-id` contains a randomly generated UUID used only to identify the generated
  project's local Riprap resources.
- The launch scripts create the file atomically on first use when it does not exist.
- An existing identifier must be a canonical lowercase UUID. Launching fails with an actionable
  error rather than replacing a malformed identifier or following a symbolic link.
- The identifier is non-secret shared project state intended to be committed so that directory
  moves and additional clones retain the same project identity.
- Copier updates preserve the identifier.

## Credential Volumes <!-- rq-b96d41dc -->

- Claude and Codex state use distinct Podman named volumes whose names include the project UUID and
  the agent name.
- Each agent's complete authentication and configuration state lives inside that agent's named
  volume. Because Claude otherwise keeps its top-level configuration file outside its credential
  directory, the development container points `CLAUDE_CONFIG_DIR` at the mounted Claude volume so
  that Claude's configuration file and credentials are both stored in the volume and survive removal
  of a disposable container.
- The template-owned tooling and agent images carry no agent configuration of their own. Installing
  an agent leaves no agent configuration file or configuration directory in either image, so a
  mounted volume is the only source of an agent's configuration and an agent never migrates
  image-resident configuration over the state held in the volume.
- Launching creates missing volumes and reuses existing volumes.
- The project working directory remains the only host project bind mount.
- Host paths such as `~/.claude`, `~/.claude.json`, and `~/.codex` are never mounted or copied into
  the development container.
- Removing a disposable development container does not remove its named credential volumes.
- A launcher command can reset one agent's state or all agent state for the current project. Reset
  requires explicit confirmation and never removes volumes belonging to another project UUID.
- Linux, macOS, WSL, and Windows launch paths implement the same identity and volume model.

## Repository Leak Prevention <!-- rq-638ff671 -->

- Generated `.gitignore` files reject known credential artifacts, including root-level
  `.codex/auth.json`, `.claude/.credentials.json`, `.claude.json`, and local `.env` variants. They
  also reject generated local container state, which describes one machine rather than the project.
  They reject nothing else, so no legitimate project content is hidden.
- Legitimate versioned integration files such as `.codex/hooks.json`, `.claude/settings.json`, and
  agent skill adapters remain trackable.
- A managed secret scanner examines staged Git content without printing matched secret
  values. It rejects known credential paths, private-key material, and high-confidence supported
  token formats.
- Staged scanning examines every added, copied, modified, renamed, or type-changed path represented
  by the index. It reads the staged blob rather than the working-tree file, so changing a path
  between regular-file and symbolic-link modes cannot remove that path from inspection.
- The scanner uses fake, unmistakably nonfunctional credentials in its tests.
- The same scanner supports a CI mode that examines repository content independently of local Git
  hook installation.
- Both modes produce the same result from the repository root and from any subdirectory. Failure to
  enumerate a requested set of paths or read a requested Git object is a scanner failure, not a
  successful clean scan. Diagnostic output identifies the operation and affected path or object
  without printing inspected content.
- Invoking either mode outside a Git working tree fails with an actionable diagnostic instead of
  scanning an unrelated directory or reporting that no secrets were found.
- Generated projects provide an explicit command to install the scanner as a Git hook through
  `core.hooksPath`. Installation does not replace or modify an existing custom hooks path; it stops
  with instructions for composing the hooks instead.
- Documentation recommends enabling GitHub secret scanning and push protection as a server-side
  safeguard. Local ignore rules and hooks are described as bypassable defense-in-depth controls.

## Cross-Platform Script Execution <!-- rq-9332ad0f -->

- A managed `.gitattributes` required-location exception, delivered and kept current through
  `copier update`, sets the line endings of version-controlled Riprap files so that hooks and launch
  scripts run on Linux, macOS, WSL, and Windows regardless of a contributor's `core.autocrlf`
  setting.
- Shell scripts and Git hooks, including the extensionless `pre-commit` hook and `check-secrets.sh`,
  are checked out with LF endings so they execute under the bundled shell of Git for Windows.
- PowerShell scripts are checked out with LF endings.
- Windows batch scripts are checked out with CRLF endings so `cmd.exe` control-flow constructs remain
  valid.
- Text files without a more specific rule are normalized to LF in the repository.
- A checkout on each supported host produces working-tree files whose bytes carry the endings that
  host's interpreters need. The endings are established from checked-out file content, because the
  attributes Git reports describe the rules that should apply rather than the bytes an interpreter
  will actually read. Validation discovers every version-controlled shell, PowerShell, batch, and
  command script rather than relying on a maintained list, and rejects mixed line endings within a
  file.
- `credential-state.sh` and `credential-state.ps1` expose the same actions and produce the same
  observable state: the same canonical project identity, the same project-scoped volume names, and
  the same requirement for explicit confirmation before removing a volume.

## Feature Interface <!-- rq-22e021a0 -->

- `rr.sh` and `rr.bat`
  - Ensure `.riprap/state/project-id` and the project-specific Claude and Codex volumes exist before
    launching the development container.
  - Launch without exposing host agent configuration paths.
- `rr.sh --reset-agent-state <claude|codex|all>` and the equivalent Windows command
  - Display the exact project-scoped volumes that will be removed.
  - Require interactive confirmation unless an explicit non-interactive confirmation flag is used.
- `rr.sh --install-git-hooks` and the equivalent Windows command
  - Configure the generated repository to use Riprap' version-controlled hooks when no
    conflicting `core.hooksPath` is configured.
- `.riprap/managed/hooks/check-secrets.sh --staged`
  - Inspect staged paths and blobs and exit nonzero when a supported secret is detected.
- `.riprap/managed/hooks/check-secrets.sh --repository`
  - Inspect repository content in CI and exit nonzero when a supported secret is detected.

## Gherkin Scenarios <!-- rq-898cb6e0 -->

```gherkin
Feature: Isolate agent credentials from generated projects

  @rq-9d9dea75
  Scenario: First launch creates a stable project identity and credential volumes
    Given a generated project has no ".riprap/state/project-id"
    And Podman has no credential volumes for the project
    When the project launcher starts the development environment
    Then it atomically creates a canonical lowercase UUID in ".riprap/state/project-id"
    And it creates distinct Claude and Codex named volumes containing that UUID
    And the container receives no bind mount from the host's Claude or Codex configuration paths

  @rq-113c8ccd
  Scenario: Later launches reuse project credential state
    Given a generated project has a valid project UUID
    And its Claude and Codex named volumes contain marker files
    When the project launcher starts and stops another disposable development container
    Then it reuses the same named volumes
    And both marker files remain present

  @rq-fb3e7cc2
  Scenario: Claude stores its configuration file inside its named volume
    Given a generated project with a valid project UUID and an existing Claude named volume
    When the development container launches
    Then Claude's top-level configuration file path resolves within the mounted Claude volume
    And a file written at that path in one container remains readable at that path after the
      container is removed and a new development container launches

  @rq-4e428654
  Scenario: Template-owned images carry no agent configuration
    Given a project rendered from the Riprap template
    When the template-owned tooling and agent images are built
    Then neither image contains a Claude configuration file at the default configuration path
    And neither image contains a Claude configuration directory

  @rq-6135fc70
  Scenario: A malformed project identity blocks launch safely
    Given ".riprap/state/project-id" is malformed or is a symbolic link
    When the project launcher starts the development environment
    Then launch fails before Podman runs
    And the existing path is not replaced or modified

  @rq-f957f555
  Scenario: Reset removes only selected project credential state
    Given two generated projects have distinct project UUIDs and credential volumes
    When the first project resets its Codex state with explicit confirmation
    Then only the first project's Codex volume is removed
    And both Claude volumes remain
    And the second project's Codex volume remains

  @rq-d89e4c89
  Scenario: Version-controlled hooks and shell scripts are marked for LF checkout
    Given a project rendered from the Riprap template
    When the effective Git "eol" attribute is evaluated for the version-controlled scripts
    Then ".riprap/managed/hooks/pre-commit" has an "eol" attribute of "lf"
    And ".riprap/managed/hooks/check-secrets.sh" has an "eol" attribute of "lf"
    And "rr.sh" has an "eol" attribute of "lf"

  @rq-dbd3a295
  Scenario: Windows batch scripts are marked for CRLF checkout
    Given a project rendered from the Riprap template
    When the effective Git "eol" attribute is evaluated for "rr.bat"
    Then "rr.bat" has an "eol" attribute of "crlf"

  @rq-f8bf5e72
  Scenario: Known credential files are ignored without hiding integration configuration
    Given a generated project
    When Git ignore rules are evaluated
    Then root-level Codex and Claude credential artifacts are ignored
    And local environment-secret files are ignored
    And ".codex/hooks.json" is not ignored
    And ".claude/settings.json" is not ignored
    And agent skill adapters are not ignored

  @rq-aeab49a7
  Scenario: Staged credential material is rejected without disclosure
    Given a generated Git repository has staged files containing fake supported credential patterns
    When the staged-content secret scanner runs
    Then it exits nonzero
    And it identifies each affected path and credential category
    And its output does not contain the matched credential values

  @rq-a7cf7d43
  Scenario: A staged type change remains subject to secret scanning
    Given a generated Git repository has a tracked regular file
    And the index changes that path to a symbolic link whose staged blob contains a fake supported
      credential pattern
    When the staged-content secret scanner runs
    Then it exits nonzero
    And it identifies the affected path and credential category
    And its output does not contain the matched credential value

  @rq-0bb9767e
  Scenario: Legitimate agent integration files pass secret scanning
    Given a generated Git repository has staged ordinary Riprap agent settings and adapters
    When the staged-content secret scanner runs
    Then it exits successfully

  @rq-50bb2037
  Scenario: Hook installation preserves an existing hook configuration
    Given a generated Git repository already has a custom "core.hooksPath"
    When Riprap hook installation is requested
    Then installation exits nonzero with composition instructions
    And the existing "core.hooksPath" is unchanged

  @rq-ba5ee81b
  Scenario: CI rejects credential material without local hook installation
    Given a generated repository contains a fake supported credential in tracked content
    And no local Git hook is installed
    When the repository-mode secret scanner runs in GitHub Actions
    Then the workflow fails without printing the credential value

  @rq-0a4106f0
  Scenario: Repository scanning is independent of the caller's directory
    Given a generated repository contains a fake supported credential in tracked content
    When the repository-mode secret scanner runs from the repository root and from a subdirectory
    Then both invocations exit nonzero
    And both identify the same affected repository-relative path and credential category

  @rq-0ce3a836
  Scenario: Scanning outside a Git repository fails explicitly
    Given the current directory is outside a Git working tree
    When either secret-scanner mode runs
    Then it exits nonzero
    And its diagnostic states that no repository could be identified

  @rq-cdb90fb3
  Scenario: An unreadable requested Git object fails closed
    Given Git reports a path or object for inspection
    And the scanner cannot read that requested object
    When the secret scanner runs
    Then it exits nonzero
    And its diagnostic identifies the failed inspection without printing repository content

  @rq-003ece26
  Scenario: A Windows checkout carries the line endings its interpreters need
    Given the repository is checked out on Windows
    When every version-controlled script is discovered and its working-tree bytes are examined
    Then every ".bat" and ".cmd" script uses CRLF for every line ending
    And every ".sh" and ".ps1" script uses LF for every line ending
    And the extensionless "pre-commit" hook ends its lines with LF

  @rq-6b0d184f
  Scenario: The Windows credential helper creates the same project identity
    Given a generated project has no ".riprap/state/project-id"
    When the Windows credential helper ensures project state
    Then it creates a canonical lowercase UUID in ".riprap/state/project-id"
    And it creates the Claude and Codex volume names the shell helper creates for that UUID

  @rq-5e481eb3
  Scenario: The Windows credential helper reuses an existing project identity
    Given a generated project has a valid project UUID
    When the Windows credential helper ensures project state
    Then the project identity is unchanged
    And the container runtime receives no volume creation command

  @rq-8c955028
  Scenario: The Windows reset requires explicit confirmation
    Given a generated project with existing credential volumes
    When the Windows credential helper resets agent state without a confirmation flag
    Then no volume is removed

  @rq-77328390
  Scenario: A malformed project identity blocks the Windows launcher
    Given ".riprap/state/project-id" is malformed
    When the Windows launcher starts the development environment
    Then launching fails
    And no development container starts
```
