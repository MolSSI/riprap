# Feature: Riprap Development Container <!-- rq-da673d77 -->

The development environment composes a stable template-owned tooling image, a refreshable
template-owned agent image, and a project-owned image. The tooling image provides the common
command-line tools needed to develop a generated project and to apply or validate Riprap
template updates. The agent image adds the supported AI agents at current releases, refreshed on a
bounded schedule that requires no routine action from the user. The project-owned image may add
further tools without replacing either template-owned layer.

## Base Tooling <!-- rq-fc6358df -->

- The image the tooling layer builds on is a project property chosen when the project is generated,
  defaulting to a current Ubuntu LTS release. A project whose software targets GPUs names a vendor
  image that supplies the GPU toolchain, such as an NVIDIA CUDA development image.
- Supported base images are Ubuntu- or Debian-derived, because the tooling and language layers
  install packages with the Debian package manager and with `pipx`. Vendor GPU images built on
  Ubuntu therefore carry the whole tooling layer unmodified, and a base image that is not
  Debian-derived is outside what the tooling layer supports.
- The base image selection changes only what the tooling layer builds on. The agent image is based
  on the tooling image and the project-owned image on the agent image regardless of which base image
  a project chose, so choosing a GPU base image costs a project none of the layering, refresh, or
  fallback behavior described here.
- The base image provides the Copier CLI for every supported project language.
- Copier is installed as an isolated Python CLI application with `pipx`.
- The installed Copier release is compatible with the template's declared minimum Copier major
  version.
- The `copier` executable is available on `PATH` in interactive development containers.
- The tooling image contains no Claude or Codex installation. It builds independently of agent
  release selection and refresh state.
- The agent image is based on the tooling image and provides the Claude and Codex command-line
  agents on `PATH` in interactive development containers.
- The project-owned image is based on the agent image.
- Refreshing agents rebuilds the agent image without rebuilding the tooling image or conflating an
  agent download failure with a tooling-image build failure.

## Agent Releases <!-- rq-ce1eb03c -->

- Each supported agent is installed at its current release by default. No routine user action keeps
  the agents current.
- The development container disables the agents' in-container automatic updaters through
  `DISABLE_AUTOUPDATER`. An agent that updates itself inside a disposable container installs into a
  path that is not a mounted volume, so the update is discarded when the container is removed and
  is repeated every session. The agent image is therefore the only thing that determines which
  agent release runs.
- A launcher records an agent release only when the built candidate image's version output contains
  a numeric `major.minor.patch` release core. Surrounding text and suffixes such as `1.2.3-beta`
  are accepted; the recorded release is the numeric `1.2.3` core. Output without a parseable release
  core is a refresh failure: the agent image is left unlabeled and the successful build key is
  unchanged. A launcher never records a release value drawn from its ambient environment, so a
  variable that happens to share a name with a build-key assignment cannot reach an image label.
- Agent program files live in the image, never inside a credential volume. Where an agent installs
  its program beneath its own configuration home, the image installs the program under an
  image-owned configuration home and the container points that agent's configuration home at the
  mounted volume, which then holds credentials and session state only. A program installed inside a
  credential volume would shadow the installed release, because the volume takes precedence over
  the image at that path, and would be destroyed by an agent state reset.

## Agent Refresh Schedule <!-- rq-f3736651 -->

- `.riprap/podman/agent-build.env` is the successful agent build key. It records the release
  selection used by the installed agent image, as the assignments `CLAUDE_VERSION` and
  `CODEX_VERSION`, together with a `REFRESH` value that changes on the refresh schedule.
- Before an agent refresh, the launcher derives a candidate build key without replacing the
  successful build key. The agent image build uses the candidate as its cache identity, so a change
  to the candidate rebuilds the agent installation layers while an unchanged candidate reuses them.
- A successful agent-image build records its exact installed Claude and Codex releases in image
  labels. The launcher verifies those labels and atomically promotes the candidate to the successful
  build key only after the build succeeds. The image labels are authoritative if local state and an
  image ever disagree.
- A failed or interrupted build leaves the successful build key unchanged and removes transient
  candidate state.
- The build key is generated local state. It is never committed, and generated `.gitignore` files
  reject it, so it describes one machine's container rather than a property of the project.
- When no pin is present, the recorded release for each agent is `latest` and `REFRESH` is the
  current ISO week. The agents are therefore reinstalled at most once per calendar week, which
  bounds how far behind the installed releases can fall. A launch that crosses a week boundary
  refreshes sooner than a full seven days rather than later, so the bound always holds.
- Because the build key's contents determine the refresh, launching repeatedly within one week
  reuses the cached agent layers and contacts no release metadata.
- The shell and Windows launch paths derive the same ISO-8601 week-year and week for any given
  date, including dates whose ISO week-year differs from their calendar year. Agreement is
  established by deriving both stamps for the same date and comparing the results, not by
  inspecting either implementation's source text.
- The shell launch path derives its current refresh stamp using commands and options available in
  the default userland of both supported Unix hosts, Linux and macOS. Normal launching does not
  depend on GNU-only date parsing extensions.

## Optional Release Pin <!-- rq-5e710604 -->

- `.riprap/agent-pin.env` is an optional, user-created file that pins one or both agents to an
  exact release, using the same `CLAUDE_VERSION` and `CODEX_VERSION` assignments. It does not exist
  in a generated project until a user creates it, so the unpinned schedule above is the default.
- A pinned agent is installed at exactly the pinned release. An unpinned agent continues to track
  its current release.
- While every agent is pinned, `REFRESH` records that the build key is pinned rather than the
  current week, so the schedule does not reinstall pinned releases week after week. While any agent
  is still unpinned, `REFRESH` continues to record the week, because that agent must keep tracking
  its current release; a pinned agent is then reinstalled at its pinned release, which costs a
  download but never changes what is installed. Removing the file returns every agent to the
  refresh schedule at the next launch.
- A present pin is a strict assignment file. It contains one or both of `CLAUDE_VERSION` and
  `CODEX_VERSION`, each at most once and with a nonempty exact release version. Empty files, empty
  values, duplicate assignments, unknown names, malformed lines, and non-exact versions fail the
  launch with an actionable message before any image is built. Falling back to the current release
  would silently discard the pin a user added deliberately, which is the opposite of what pinning
  is for.
- Every launcher applies the same pin validation and reports the same defect for the same pin
  content. Each line is checked in a fixed precedence: line structure, then whether the name is
  recognized, then whether the name is repeated, then whether the value is nonempty, then whether
  the value is an exact release version. The first failing check determines the message, so a name
  that is both unrecognized and paired with a non-version value is reported as an unrecognized name
  on every platform. A user who moves between hosts, or who reads a colleague's error message,
  sees one account of what is wrong with the file.
- The pin exists so that a bad agent release can be escaped without waiting for an upstream fix. It
  is ordinary project content: a user may commit it to hold a whole team at one release, or leave
  it untracked to affect one machine.

## Launch Resilience <!-- rq-3290745a -->

- The tooling image must build successfully before agent refresh fallback is considered. A tooling
  build failure stops the launch even when an older tooling or agent image exists, because the
  failure may represent an incompatible template or toolchain change.
- An agent refresh requires network access. When only the agent-image build fails and a previously
  successful agent image based on the current tooling image exists, launching reports that the
  refresh failed and continues with that agent image. Its labels and the successful build key remain
  unchanged.
- When the agent-image build fails and no compatible successful agent image exists, launching fails.
  Starting without the agents or with an agent image based on different tooling would be misleading.

## Container Run Options <!-- rq-70d01853 -->

- `.riprap/podman/run-options` supplies container runtime options for the interactive development
  container beyond those the template always applies. It is a user-owned seed file: the template
  creates it once and preserves it thereafter, so options a project enables survive template
  updates. It is ordinary project content, so a team may commit it to share one environment or
  leave it untracked to configure a single machine.
- As delivered, every line of the file is commentary, so a generated project starts with no
  additional runtime options until a user enables some. The commentary documents the format and
  carries a commented example granting the container access to the host's GPUs, so a project that
  chose a GPU base image reaches a working GPU container by uncommenting delivered lines rather
  than by composing runtime flags itself.
- Each line that is neither blank nor a comment is exactly one container runtime argument, passed
  to the runtime verbatim. A line whose first non-blank character is `#` is a comment. An option
  carrying a value occupies one line in single-token `--name=value` form.
- The options apply to the interactive development container in addition to the workspace mount,
  credential volumes, agent configuration environment, and working directory, which are present on
  every launch. The project's options are supplied after those, so a runtime that resolves a
  repeated option in favor of its last occurrence resolves it in the project's favor.
- One argument per line exists so that options reach the runtime without shell word splitting or
  re-quoting, on hosts whose shells disagree about both. A launcher accepts a line only when it is
  a single token that contains no whitespace and begins with `-`. Any other line fails the launch
  before a container starts, identifying the file and the offending line. A user who writes an
  option and its value separated by a space intends two arguments; passing that line as one
  argument instead would fail obscurely inside the runtime, and splitting it would reintroduce the
  quoting rules the format exists to avoid.
- Structural acceptance is the launcher's only interpretation of the file. A launcher recognizes no
  particular option, attaches no meaning to device or privilege options, and grants no access of
  its own, so the container receives exactly the options the user wrote and nothing further. New
  runtime options therefore need no launcher change.
- Every launcher applies the same validation and reports the same defect for the same file
  content, and an absent file is equivalent to one that enables no options.

## Feature Interface <!-- rq-4afcfc2c -->

- `rr.sh` and `rr.bat`
  - Validate the complete optional pin and derive a candidate from it and the current ISO week
    before building any image.
  - Stop before building when a pin is malformed, identifying the offending content.
  - Build the tooling image independently from the agent refresh and stop on a tooling build failure.
  - Build and verify the agent image, promote successful state atomically, and discard candidate
    state after failure or interruption.
  - Continue with a compatible successful agent image, after reporting the failure, only when the
    agent refresh fails.
  - Read a numeric `major.minor.patch` release core for each agent from the built candidate image,
    accepting surrounding text and release suffixes, and treat output without such a core as a
    refresh failure.
  - Validate the project's container run options and stop before starting a container when a line
    is not a single whitespace-free argument beginning with `-`.
  - Start the interactive development container with the project's run options applied after the
    workspace mount, credential volumes, agent configuration environment, and working directory.

## Launcher Validation <!-- rq-6ed9bff7 -->

- Each launcher is validated on the platform whose interpreter runs it: the shell launcher under a
  POSIX shell, and the Windows launcher under `cmd.exe` with the PowerShell helpers it invokes.
  Launch orchestration is written twice, in two languages with different quoting, control-flow, and
  variable-expansion rules, so validating one launcher establishes nothing about the other.
- Launcher validation substitutes a mock container runtime on `PATH` for Podman. Pin validation,
  candidate and build-key state, build sequencing, version verification, and failure fallback are
  all observable from the commands a launcher issues and the state it writes, so none of them
  requires a real image build.
- Windows launcher validation therefore requires no container runtime, virtualization, or Linux
  subsystem, and it runs on a stock Windows continuous integration runner.
- Image content is validated separately, by building the real images where a rootless Podman
  runtime is available. The two validations do not overlap: a launcher check never builds an image,
  and an image check never runs a launcher.

## Gherkin Scenarios <!-- rq-88b04d5f -->

```gherkin
Feature: Riprap development container

  @rq-a32974ac
  Scenario: Copier is available in a generated Rust development container
    Given a Rust project is rendered from the Riprap template with Copier
    When the generated template-owned base container image is built
    Then the image build succeeds
    And running "copier --version" in the built image succeeds
    And the reported Copier major version is compatible with the template

  @rq-876d30dd
  Scenario: Copier is available in a generated Python development container
    Given a Python project is rendered from the Riprap template with Copier
    When the generated template-owned base container image is built
    Then the image build succeeds
    And running "copier --version" in the built image succeeds
    And the reported Copier major version is compatible with the template

  @rq-276c546b
  Scenario: Installed agent releases match authoritative image labels
    Given a generated project whose candidate records an exact release for each agent
    When the template-owned agent image is built successfully
    Then its labels record the exact installed Claude and Codex releases
    And running "claude --version" in the built image reports the labeled Claude release
    And running "codex --version" in the built image reports the labeled Codex release
    And the successful build key matches the verified image labels

  @rq-b25f8408
  Scenario: Agent installation is isolated from the tooling image
    Given a generated project rendered from the Riprap template
    When its template-owned images are built
    Then the tooling image contains the base packages, Copier, and language toolchain
    And the tooling image contains no agent installation
    And the agent image is based on the tooling image
    And the project-owned image is based on the agent image

  @rq-d09c17d0
  Scenario: Agent programs are installed outside the credential volume paths
    Given a generated project rendered from the Riprap template
    When the template-owned agent image is built
    Then each agent executable resolves to a program path that no credential volume mounts over
    And the image contains no agent program files beneath a credential volume mount point

  @rq-7c6a2afa
  Scenario: An unpinned launch records the current week and tracks current releases
    Given a generated project has no release pin
    When the project launcher starts the development environment
    Then the build key records "latest" for each agent
    And the build key records the current ISO week

  @rq-145d819f
  Scenario: A second launch in the same week reuses the cached agent layers
    Given a generated project whose agent image was built earlier in the current ISO week
    And the project has no release pin
    When the project launcher starts the development environment again
    Then the build key is unchanged
    And the agent installation layers are served from the build cache

  @rq-62939bfc
  Scenario: A new week rebuilds the agent layers
    Given a generated project whose agent image was built in an earlier ISO week
    And the project has no release pin
    When the project launcher starts the development environment
    Then the build key records the current ISO week
    And the agent installation layers are rebuilt with no additional build arguments

  @rq-c82c7b32
  Scenario: A pin installs an exact release and suspends the weekly refresh
    Given a generated project pins each agent to an exact release
    When the project launcher starts the development environment
    Then the build key records each pinned release
    And the build key does not record an ISO week
    And launching again in a later week leaves the build key unchanged

  @rq-b06efb1e
  Scenario: Removing a pin returns the agents to the refresh schedule
    Given a generated project whose build key records pinned releases
    When the release pin is removed
    And the project launcher starts the development environment
    Then the build key records "latest" for each agent
    And the build key records the current ISO week

  @rq-6c8f6c05
  Scenario: A malformed pin stops the launch before any image is built
    Given a release pin records a value that is not an exact release version
    When the project launcher starts the development environment
    Then launching fails
    And the failure message identifies the offending assignment
    And no image is built

  @rq-0aa08b69
  Scenario: An empty pin stops the launch before any image is built
    Given a release pin contains no assignments
    When the project launcher starts the development environment
    Then launching fails
    And the failure message identifies the empty pin file
    And no image is built

  @rq-0b49d1fa
  Scenario: An empty pin value stops the launch before any image is built
    Given a release pin contains `CLAUDE_VERSION=`
    When the project launcher starts the development environment
    Then launching fails
    And the failure message identifies the empty value
    And no image is built

  @rq-5f5a1830
  Scenario: An unknown pin name stops the launch before any image is built
    Given a release pin contains `CLAUDE_VERSOIN=1.2.3`
    When the project launcher starts the development environment
    Then launching fails
    And the failure message identifies the unknown name
    And no image is built

  @rq-bba1fa27
  Scenario: A duplicate pin name stops the launch before any image is built
    Given a release pin contains two `CLAUDE_VERSION` assignments
    When the project launcher starts the development environment
    Then launching fails
    And the failure message identifies the duplicate name
    And no image is built

  @rq-08b8e355
  Scenario: A malformed pin line stops the launch before any image is built
    Given a release pin contains a line without an assignment delimiter
    When the project launcher starts the development environment
    Then launching fails
    And the failure message identifies the malformed line
    And no image is built

  @rq-dc4bf1b1
  Scenario: A failed refresh falls back to a compatible agent image
    Given a generated project whose tooling image is current
    And whose successful agent image was built in an earlier ISO week from that tooling image
    And the agent image refresh fails
    When the project launcher starts the development environment
    Then the launcher reports that the agent refresh failed
    And the development container starts from the successful agent image
    And the successful build key is unchanged
    And the running agent releases match the successful image labels

  @rq-152d1311
  Scenario: A failed refresh with no compatible agent image stops the launch
    Given a generated project has no successful agent image based on its current tooling image
    And the agent image refresh fails
    When the project launcher starts the development environment
    Then launching fails
    And no development container starts

  @rq-4097cd5c
  Scenario: A tooling image build failure never uses refresh fallback
    Given a generated project has a previously successful tooling and agent image
    And the current tooling image build fails
    When the project launcher starts the development environment
    Then launching fails
    And the launcher does not describe the failure as an agent refresh failure
    And no development container starts

  @rq-26d8643a
  Scenario: Windows and shell launchers agree at ISO year boundaries
    Given a set of UTC dates whose ISO week-year differs from their calendar year
    When the shell and Windows implementations each derive a refresh stamp for every date
    Then the two implementations produce identical stamps for every date
    And each stamp equals the ISO-8601 week-year and week for its date

  @rq-cfefd5aa
  Scenario: The shell launcher derives its refresh stamp on every supported Unix host
    Given a generated project on Linux or macOS with the host's default date utility
    When the shell launcher prepares the current agent build key
    Then preparation succeeds
    And the refresh stamp is the current ISO-8601 week-year and week

  @rq-13f28b2e
  Scenario: Both launchers report the same defect for the same invalid pin
    Given a release pin that fails validation
    When each launcher validates that pin on its own platform
    Then every launcher fails the launch
    And every launcher identifies the same defect

  @rq-c2cdf6d8
  Scenario: An unrecognized pin name outranks a non-exact pin value
    Given a release pin contains `CLAUDE_VERSOIN=not-a-version`
    When the project launcher starts the development environment
    Then launching fails
    And the failure identifies the unknown name rather than the value format

  @rq-17a864bb
  Scenario: The Windows launcher validates the pin before building
    Given a release pin records a value that is not an exact release version
    When the Windows launcher starts the development environment
    Then launching fails
    And the failure message identifies the offending assignment
    And no image is built

  @rq-13d744b1
  Scenario: The Windows launcher stops on a tooling build failure
    Given the container runtime fails every image build
    When the Windows launcher starts the development environment
    Then launching fails
    And the launcher does not describe the failure as an agent refresh failure
    And no candidate state remains

  @rq-b68a63b5
  Scenario: The Windows launcher falls back to a compatible agent image
    Given a successful agent image whose tooling-image label matches the current tooling image
    And the agent image build fails
    When the Windows launcher starts the development environment
    Then the launcher reports that the agent refresh failed
    And the development container starts from the successful agent image
    And the successful build key is unchanged

  @rq-f69aa150
  Scenario: The Windows launcher stops when no compatible agent image exists
    Given no successful agent image based on the current tooling image exists
    And the agent image build fails
    When the Windows launcher starts the development environment
    Then launching fails
    And no development container starts

  @rq-41eeda01
  Scenario: The Windows launcher refuses an agent version it cannot parse
    Given the built candidate image reports output without a numeric `major.minor.patch` release core
    When the Windows launcher starts the development environment
    Then the agent image is not labeled with that version
    And the successful build key is unchanged

  @rq-fedf48c5
  Scenario: A launcher ignores an ambient variable named like a build-key assignment
    Given the environment sets `CLAUDE_VERSION` to an exact release version
    And the built candidate image reports a different parseable Claude release core
    When the project launcher starts the development environment
    Then the recorded Claude release is the release core parsed from the candidate image

  @rq-ac53295e
  Scenario: The build key is not committed
    Given a generated project whose launcher has written the build key
    When Git ignore rules are evaluated
    Then ".riprap/podman/agent-build.env" is ignored

  @rq-fae13c6f
  Scenario: Launching disables the agents' in-container automatic updaters
    Given a generated project with a valid project UUID
    When the project launcher starts the development environment
    Then the container environment sets "DISABLE_AUTOUPDATER"

  @rq-c75bb5d9
  Scenario: A project defaults to an Ubuntu LTS base image
    Given a project is rendered from the Riprap template without naming a base image
    When the generated template-owned tooling image definition is read
    Then it builds on a current Ubuntu LTS release

  @rq-d6488ee9
  Scenario: A GPU base image carries the whole tooling layer
    Given a project is rendered from the Riprap template naming an Ubuntu-derived CUDA base image
    When the generated template-owned tooling image is built
    Then the image build succeeds
    And running "copier --version" in the built image succeeds
    And the language toolchain for the project's language is present in the built image
    And the CUDA compiler supplied by the base image is present in the built image

  @rq-f2f0525e
  Scenario: Agent and project layers are unaffected by the base image
    Given a project is rendered from the Riprap template naming an Ubuntu-derived CUDA base image
    When its template-owned images are built
    Then the agent image is based on the tooling image
    And the project-owned image is based on the agent image
    And the tooling image contains no agent installation

  @rq-83545aca
  Scenario: A generated project enables no additional run options
    Given a project is rendered from the Riprap template
    When the project launcher starts the development environment
    Then the container runtime receives no arguments beyond the template-owned ones

  @rq-7471ee4f
  Scenario: An enabled run option reaches the container runtime
    Given a run options file whose only uncommented line is "--shm-size=8g"
    When the project launcher starts the development environment
    Then the container runtime receives the argument "--shm-size=8g"

  @rq-f881a732
  Scenario: Enabling the delivered GPU example grants device access
    Given a run options file with the delivered GPU example lines uncommented
    When the project launcher starts the development environment
    Then the container runtime receives every uncommented line as a separate argument
    And it receives them in the order the file lists them

  @rq-a3420977
  Scenario: Run options do not displace the template-owned container configuration
    Given a run options file whose only uncommented line is "--shm-size=8g"
    When the project launcher starts the development environment
    Then the container runtime receives the workspace mount at "/work"
    And it receives both credential volume mounts
    And it receives the agent configuration environment
    And the project's option follows the template-owned arguments

  @rq-173cab03
  Scenario: Comments and blank lines enable no options
    Given a run options file containing only comment lines, indented comment lines, and blank lines
    When the project launcher starts the development environment
    Then the container runtime receives no arguments beyond the template-owned ones

  @rq-b6ce2749
  Scenario: An absent run options file enables no options
    Given a generated project whose run options file has been deleted
    When the project launcher starts the development environment
    Then launching succeeds
    And the container runtime receives no arguments beyond the template-owned ones

  @rq-32ffafe7
  Scenario: A run option containing whitespace stops the launch
    Given a run options file whose only uncommented line is "--device nvidia.com/gpu=all"
    When the project launcher starts the development environment
    Then launching fails
    And the failure message identifies the offending line
    And no container starts

  @rq-eb18200a
  Scenario: A run option that is not an option stops the launch
    Given a run options file whose only uncommented line is "device=all"
    When the project launcher starts the development environment
    Then launching fails
    And the failure message identifies the offending line
    And no container starts

  @rq-0e32b682
  Scenario: Both launchers report the same defect for the same invalid run options
    Given a run options file that fails validation
    When each launcher validates that file on its own platform
    Then every launcher fails the launch
    And every launcher identifies the same defect

  @rq-0b67fe5f
  Scenario: The Windows launcher applies the project's run options
    Given a run options file whose only uncommented line is "--shm-size=8g"
    When the Windows launcher starts the development environment
    Then the container runtime receives the argument "--shm-size=8g"
    And it receives the template-owned arguments

  @rq-2f86b6aa
  Scenario: A template update preserves enabled run options
    Given a generated project whose run options file has been edited to enable an option
    When the project adopts a later template release with "copier update"
    Then the run options file retains the user's edit

```
