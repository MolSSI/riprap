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
  source files, language manifests, `README.md`, `LICENSE`, the project-owned root
  `Containerfile`, and the root agent instruction files, which a project extends with its own
  guidance while the managed instructions they reference remain under `.riprap/managed/`.
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
- Every managed required-location exception carries a visible managed marker among its leading
  lines, whether or not it delegates, and contains only the delegation or configuration required at
  that path. The marker may follow an interpreter directive rather than opening the file.
- A managed required-location exception whose file format cannot express comments carries no
  marker. The marker-exempt exceptions are enumerated explicitly, and an exception whose format can
  express comments is never marker-exempt.
- The set of managed required-location exceptions is explicit and mechanically validated. Adding
  an exception requires a deliberate ownership decision rather than silently expanding the set.
- Riprap uses portable wrapper scripts or a tool's native delegation mechanism for managed
  exceptions. It does not use filesystem symbolic links to implement the ownership layout.

## Update and Validation Contract <!-- rq-f9576090 -->

- Template validation classifies every rendered path and fails when a path has no ownership class,
  has more than one ownership class, or violates the location rules for its class.
- Validation rejects a managed file outside `.riprap/managed/` unless it is an approved
  required-location exception.
- Validation rejects an approved required-location exception that carries no managed marker unless
  that exception is marker-exempt, and rejects a marker-exempt declaration for a format that can
  express comments.
- Validation rejects a user customization under `.riprap/managed/` and machine-local state outside
  `.riprap/state/`.
- Every `.riprap` path a rendered file references names one of the three ownership directories, so
  a reference to a component directory that the layout does not define fails validation.
- Every referenced path under `.riprap/managed/` resolves to a file in the rendered project.
  References under `.riprap/user/` and `.riprap/state/` name files that a project or a launch
  creates, so their absence at render time is not a failure.
- `copier update` updates managed implementations and managed required-location exceptions while
  preserving user-owned files.
- Riprap declares no Copier feature that requires a trust option. Generating a project and
  updating one both succeed with the commands the documentation gives, and the rendered layout is
  the only layout Riprap produces, so no update has to reconcile an earlier arrangement of the
  same files.
- Generated ignore rules exclude machine-local state but do not hide shared project state,
  user-owned customization, or managed files.
- A managed file that projects are expected to extend separates a managed region from a clearly
  marked project-owned region, and orders the two so that `copier update` revises the managed
  region without disturbing project content. Generated ignore rules follow this arrangement, with
  the project-owned region last.
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
- `.riprap/managed/ownership-exceptions`
  - Enumerates the approved managed required-location exceptions and identifies which of them are
    marker-exempt.
- Template ownership validation
  - Classifies every path rendered by each supported project variant and enforces the ownership,
    exception, marker, reference-integrity, preservation, ignore, and symbolic-link rules in this
    document.

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

  @rq-64f745b6
  Scenario: An approved exception without a managed marker fails validation
    Given a rendered file at an approved required-location exception path
    And its format can express comments
    And none of its leading lines carry the managed marker
    When template ownership validation runs
    Then validation exits nonzero
    And it identifies the unmarked path

  @rq-23cdd66f
  Scenario: A marker-exempt exception needs no managed marker
    Given a rendered file at an approved required-location exception path
    And its format cannot express comments
    And the exception is enumerated as marker-exempt
    When template ownership validation runs
    Then validation accepts the unmarked file

  @rq-215e96be
  Scenario: A reference to an undefined component directory fails validation
    Given a rendered file references a path under ".riprap"
    And the first path segment after ".riprap" is not "managed", "user", or "state"
    When template ownership validation runs
    Then validation exits nonzero
    And it identifies the referencing file and the undefined path

  @rq-f3bedd31
  Scenario: A reference to a missing managed implementation fails validation
    Given a rendered file references a path under ".riprap/managed"
    And no file exists at that path in the rendered project
    When template ownership validation runs
    Then validation exits nonzero
    And it identifies the referencing file and the unresolved path

  @rq-c5824068
  Scenario: Generating and updating a project need no trust option
    Given a later revision of the template changes a managed implementation
    When "copier copy" generates a project without a trust option
    And "copier update" applies the later revision without a trust option
    Then both commands exit zero
    And the project contains the later revision of the managed implementation

  @rq-e558bda9
  Scenario: User customization survives a template update
    Given a generated project whose file under ".riprap/user" has been customized
    And a later template revision changes managed implementations
    When "copier update" applies the later revision
    Then the customized user-owned file is unchanged
    And the managed implementations contain the later revision

  @rq-602c57d1
  Scenario: Project ignore rules survive a managed ignore-rule update
    Given a generated project has added rules to the project-owned region of its ignore file
    And a later template revision adds a rule to the managed region
    When "copier update" applies the later revision
    Then the project's own rules are unchanged
    And the managed rule is present
    And the ignore file contains no merge conflict markers

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
