# Feature: Template Ownership Layout <!-- rq-fe44119c -->

Riprap makes file ownership visible from location. Generated repositories separate Riprap-managed
implementations, supported project customization, and generated state while retaining conventional
or tool-mandated paths where moving a file would make the project less idiomatic or prevent an
external tool from discovering it.

## Ownership Classes <!-- rq-5b73c38c -->

- Every file rendered into a generated repository belongs to exactly one of three ownership
  classes: managed, user-owned, or state.
- `.riprap/managed/` contains Riprap-owned implementations that may change during
  `copier update`. Users do not customize files in this directory.
- `.riprap/user/` contains supported project customization. Seeded files in this directory are
  created once and preserved during `copier update`.
- `.riprap/state/` contains state generated for a project or machine. Each state file explicitly
  declares whether it is shared project metadata that may be committed or machine-local state that
  is ignored.
- Conventional project content remains at its standard location and is user-owned. This includes
  source files, language manifests, `README.md`, `LICENSE`, and the project-owned root
  `Containerfile`.
- No canonical managed implementation or supported customization file lives directly under
  `.riprap/skills`, `.riprap/hooks`, or `.riprap/podman`.

## Required-Location Exceptions <!-- rq-12165531 -->

- A managed file exists outside `.riprap/managed/` only when a project convention or external tool
  requires its path.
- A managed entry point outside `.riprap/managed/` is a visibly marked, minimal adapter that
  delegates to a canonical implementation under `.riprap/managed/` while preserving its documented
  command-line behavior, exit status, and working-directory behavior.
- Agent discovery files and settings at agent-mandated paths contain only the discovery,
  configuration, and convention translation that cannot live in the canonical agent-neutral
  implementation.
- A required-location file that cannot delegate is visibly marked as managed and contains only the
  configuration required at that path.
- The set of managed required-location exceptions is explicit and mechanically validated. Adding
  an exception requires a deliberate ownership decision rather than silently expanding the set.
- Riprap uses portable wrapper scripts or a tool's native delegation mechanism for managed
  exceptions. It does not use filesystem symbolic links to implement the ownership layout.

## Update and Validation Contract <!-- rq-f9576090 -->

- Template validation classifies every rendered path and fails when a path has no ownership class,
  has more than one ownership class, or violates the location rules for its class.
- Validation rejects a managed file outside `.riprap/managed/` unless it is an approved
  required-location exception.
- Validation rejects a user customization under `.riprap/managed/` and machine-local state outside
  `.riprap/state/`.
- `copier update` updates managed implementations and managed required-location exceptions while
  preserving user-owned files.
- Generated ignore rules exclude machine-local state but do not hide shared project state,
  user-owned customization, or managed files.
- The rendered repository has one canonical ownership layout and no parallel canonical tree at
  direct `.riprap/skills`, `.riprap/hooks`, or `.riprap/podman` paths.

## Feature Interface <!-- rq-2debabe1 -->

- `rr.sh`
  - Is a managed root entry-point adapter that delegates to
    `.riprap/managed/launch/rr.sh` without changing arguments, exit status, or the caller's project
    working directory.
- `rr.bat`
  - Is a managed root entry-point adapter that delegates to the Windows launcher under
    `.riprap/managed/launch/` without changing arguments, exit status, or the caller's project
    working directory.
- `.riprap/managed/hooks/`
  - Contains the canonical version-controlled Git hook and secret-scanning implementations.
- Template ownership validation
  - Classifies every path rendered by each supported project variant and enforces the ownership,
    exception, preservation, ignore, and symbolic-link rules in this document.

## Gherkin Scenarios <!-- rq-5d572c3c -->

```gherkin
Feature: Make generated-file ownership visible from location

  @rq-b9f824f4
  Scenario: A generated project separates the three ownership classes
    Given a project is rendered from the Riprap template
    When its rendered paths are classified
    Then every canonical Riprap implementation is under ".riprap/managed"
    And every Riprap-specific customization surface is under ".riprap/user"
    And every generated project or machine state file is under ".riprap/state"
    And every rendered path has exactly one ownership class

  @rq-7c9116c2
  Scenario: Conventional project content remains user-owned at conventional paths
    Given a project is rendered from the Riprap template
    When its conventional project files are inspected
    Then its source files, language manifest, README, license when present, and root Containerfile
      remain outside ".riprap"
    And each is classified as user-owned

  @rq-37192a21
  Scenario: A required external entry point delegates to managed implementation
    Given a generated project has a launcher at a conventional root path
    When the launcher is inspected and invoked
    Then it is visibly marked as Riprap-managed
    And it delegates to a canonical implementation under ".riprap/managed"
    And it preserves the launcher's documented arguments, exit status, and working-directory
      behavior

  @rq-c618df8b
  Scenario: An unapproved managed exception fails ownership validation
    Given a rendered managed file is outside ".riprap/managed"
    And its path is not an approved required-location exception
    When template ownership validation runs
    Then validation exits nonzero
    And it identifies the unapproved path

  @rq-e558bda9
  Scenario: User customization survives a template update
    Given a generated project whose file under ".riprap/user" has been customized
    And a later template revision changes managed implementations
    When "copier update" applies the later revision
    Then the customized user-owned file is unchanged
    And the managed implementations contain the later revision

  @rq-8b0a20e7
  Scenario: Ignore rules distinguish machine and project state
    Given a project is rendered from the Riprap template
    When Git ignore rules are evaluated for files under ".riprap/state"
    Then every machine-local state file is ignored
    And shared project identity is not ignored

  @rq-d0c2c83d
  Scenario: The ownership layout uses no symbolic-link indirection
    Given a project is rendered from the Riprap template
    When every rendered path is inspected
    Then no ownership adapter is a symbolic link

  @rq-9045b67e
  Scenario: Direct Riprap component directories contain no canonical files
    Given a project is rendered from the Riprap template
    When the ".riprap" directory is inspected
    Then no canonical implementation or supported customization exists directly under "skills",
      "hooks", or "podman"
```
