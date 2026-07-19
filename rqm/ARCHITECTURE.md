# Architecture

## Purpose

Riprap provides production-quality project scaffolding for requirements-first, AI-assisted
software development. It is intended for broad community adoption rather than as a personal or
educational example. Generated repositories combine durable project guidance, reusable agent
workflows, requirements traceability, isolated development environments, and conventional language
tooling so that humans can direct and review AI-assisted work without surrendering control of the
development process.

Riprap is a versioned Copier template. Long-lived generated repositories must be able to use
`copier update` to adopt current Riprap behavior while preserving explicitly user-owned files
and customizations. Template evolution therefore treats update compatibility, clear file ownership,
and conflict avoidance as primary design constraints.

## Scope and Key Features

Riprap provides:

- A Copier-based generator and update path for new and existing repositories.
- Requirements-first workflows for establishing project architecture, planning testable features,
  implementing requirements, and checking human understanding of generated code.
- Stable requirements identifiers that connect requirements, implementation, and tests where those
  artifacts are mechanically testable.
- Agent-neutral canonical skills with thin discovery and convention adapters for individual AI
  agents.
- Project-owned skill extensions that survive template updates without requiring users to modify
  template-owned skill implementations.
- Rootless, isolated development environments containing supported AI agents, language toolchains,
  and Riprap maintenance tools.
- Launch workflows for Linux, macOS, and Windows hosts.
- Generated project variants for Rust and Python, including optional language-specific skeletons,
  tests, continuous integration, documentation, and packaging configuration.
- Explicit ownership boundaries between files that receive Riprap updates and files seeded once
  for users to maintain.

### Non-Goals

Riprap does not implement an AI coding agent, replace the supported agents' native interfaces,
or provide general-purpose AI orchestration. It is not a general project generator unrelated to
AI-assisted development and does not attempt to support every language, build system, or deployment
platform in each release.

Riprap does not treat privileged Docker containers as equivalent to its rootless isolation
boundary. General-purpose container orchestration and production application deployment are outside
its scope.

## Architectural Decisions

### Template and Ownership Model

Copier is the sole template rendering and update engine. Conditional Copier templates express
supported language and tooling variants. Riprap distinguishes among:

- Template-owned files, which may receive improvements through `copier update`.
- User-owned seed files, which Copier creates once and preserves thereafter.
- Agent-neutral user extension files, which provide stable customization points while their
  surrounding workflows remain template-owned.

New template features must assign ownership deliberately. Update behavior is part of their public
contract, not an incidental consequence of file placement.

The Riprap repository is itself a rendered instance of its own template, as recorded in
`.copier-answers.yml`: the top-level project files are generated from `template/` and adopt template
improvements through `copier update`. A template-owned file therefore exists twice in the
repository — as the source under `template/` and as the rendered copy at the top level. The source
under `template/` is the single point of edit; the rendered top-level copy is produced by
`copier update` and is never modified by hand, because a later update would overwrite manual
top-level edits.

User-owned seed files and agent-neutral extension files are a partial exception, and the exception
covers maintenance rather than creation. Copier creates such a file once and preserves it
thereafter, so its top-level copy is edited in place from then on. Its first appearance at the top
level is still Copier's work: a seed file newly added to `template/` reaches the top level by
rendering, never by being written there directly. Seeding a file by hand would leave the top level
agreeing with the template by coincidence rather than by construction, and would retire the seeding
path untested at the moment it was introduced.

Beyond the rendered instance, the repository also carries development and evaluation artifacts that
the template never distributes: Riprap' own requirements under `rqm/`, its tests, and
point-in-time analyses under `review/`. The `review/` directory holds occasional AI-generated
assessments of the project itself — for example, comparisons against similar tools or security
reviews — each recorded at `review/<category>/<date>/README.md` with its goal, date, corresponding
commit, and generating tool. These artifacts are owned by the Riprap repository, live only at
its top level, and are never rendered into a generated project.

### Agent Integration

Canonical Riprap workflows are independent of any one AI agent and live under `.riprap`.
Agent-specific directories contain thin adapters for discovery, tool vocabulary, invocation syntax,
and other interface conventions. Claude and Codex are supported agents, but the architecture allows
additional and not-yet-existing agents to be integrated without duplicating canonical workflows or
relocating user customizations.

Riprap relies on supported agents' public extension mechanisms rather than embedding or
reimplementing their runtimes. Capabilities that cannot be represented uniformly remain isolated in
the corresponding adapter.

### Development Isolation

Development runs inside an unprivileged container boundary so that AI agents do not receive broad
access to the host. Podman is the supported rootless container runtime. The design may add other
rootless isolation systems, such as Apptainer, provided they preserve the security boundary and do
not require agent-neutral workflows to depend on a particular runtime.

Host launch scripts support Linux, macOS, and Windows while presenting a consistent workspace and
tooling environment inside the container. Each host's launcher is a separate implementation held to
the same observable behavior, so a capability offered on one platform is offered on all of them.

The container image is layered by how often each layer changes and by who owns it. A template-owned
tooling image supplies the common Riprap and language toolchain. A template-owned agent image
builds on it and supplies the supported AI agents, refreshed on a bounded schedule that requires no
routine user action. A user-owned image layer supplies project-specific additions. Isolating the
agent layer keeps a failed agent download from being mistaken for a broken toolchain, and makes the
installed agent releases a recorded property of the image rather than an accident of when the image
happened to be built.

### Language Support

Rust and Python are supported generated-project languages. Language-specific files are selected by
Copier while common Riprap workflows remain language-neutral. Additional languages may be added
through isolated template branches and conventional language tooling without restructuring the
agent, requirements, ownership, or container layers.

The Riprap repository itself favors standard shell and template mechanisms for orchestration
and avoids introducing application frameworks or dependencies for behavior that existing platform
tools can express clearly.

### Requirements-First Development

High-level, expensive-to-reverse decisions live in `rqm/ARCHITECTURE.md`. Testable feature behavior
lives in focused requirements documents under `rqm/`; implementation follows those documents.
Stable opaque identifiers provide traceability for requirements that correspond to executable code
or tests.

Riprap' own traceability identifiers belong to the top-level repository: its requirements under
`rqm/` and the implementation or tests that satisfy them outside `template/`. Concrete
`rq-XXXXXXXX` identifiers from the Riprap repository do not appear anywhere under `template/`.
Template content is distributed into generated repositories, whose requirements and traceability
registries are independently owned by those projects. Keeping the namespaces separate prevents a
generated project from mistaking Riprap implementation annotations for its own requirements.

Requirements and Gherkin scenarios must describe behavior that can be validated meaningfully in the
project's automated environment. The requirements process does not manufacture executable-looking
scenarios for subjective agent behavior or other claims that the test environment cannot observe.

## Extensibility

Riprap uses composition through templates, canonical workflows, adapters, and user-owned
extension files rather than an in-process plugin framework.

The principal extension points are:

- Agent adapters, which connect a new agent's discovery and interaction conventions to canonical
  Riprap skills.
- Language variants, which contribute conditional skeleton, build, test, documentation, and CI
  templates.
- Rootless container backends, which may provide host launch and environment-building integrations
  behind the same isolation goals.
- Per-project `local.md` files and user-owned container layers, which customize generated projects
  without forking template-owned behavior.

Extensions must preserve Copier updateability and keep agent-, language-, platform-, and
project-specific concerns out of the shared core where practical.

## Testing Strategy

GitHub Actions is the authoritative automated test environment. A test or Gherkin scenario belongs
in the project only when it can execute there reliably and provide evidence about observable
behavior.

The end-to-end test matrix renders representative Rust and Python projects with Copier and verifies
that generated projects build and test successfully. It also exercises `copier update` across
supported ownership and customization boundaries. Container tests build the supported generated
container configurations.

Launch behavior separates into two layers with different testability, and the distinction decides
where each test runs. Launch orchestration — argument handling, validation of user-supplied
configuration, build sequencing, local state transitions, and failure fallback — is observable from
the commands a launcher issues and the state it writes, so it is tested against a mock container
runtime and needs no container runtime, virtualization, or Linux subsystem on the runner. Each
launcher is exercised under the interpreter that actually runs it, because the launch path is
implemented once per supported host in languages with different quoting, control-flow, and
variable-expansion rules; a launcher passing on one platform is no evidence about its counterpart.
Container runtime behavior — image contents, volume semantics, and process isolation — requires a
real rootless runtime and is tested only on runners that provide one. The two layers are tested
separately: an orchestration test never builds an image, and a runtime test never runs a launcher.

Focused tests cover deterministic tooling shipped by Riprap, including requirements-management
scripts, hooks, launch helpers, and other purely mechanical behavior. Failure paths and preservation
of user-owned data receive explicit coverage where they can be reproduced in CI.

Tests do not attempt to prove subjective prompt quality, an agent's semantic compliance with prose,
or interactive behavior that GitHub Actions cannot exercise. Static assertions that merely search
skill text for restatements of requirements are not meaningful validation and are omitted. Such
workflow text is reviewed as documentation; only its independently observable effects warrant
automated scenarios.

## Open Questions

- Which rootless container runtime should be supported after Podman, and what common interface is
  required to keep host launch behavior consistent?
- Which additional generated-project languages have sufficient community demand and conventional
  tooling to justify inclusion in the maintained CI matrix?
- Which agent behaviors can eventually be tested through stable, non-interactive interfaces without
  creating brittle tests tied to model output?
