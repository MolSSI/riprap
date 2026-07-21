# Feature: Portable Development Image <!-- rq-d86d20e0 -->

A project's development image is a transferable artifact. Building an image and executing one are
separate roles that may fall on different machines: Podman builds the image on a host that can build,
and Apptainer executes a previously exported image on a host that cannot. This allows AI-assisted
development on a managed compute cluster, where a user typically lacks the privileges, the network
access, or the local daemon that building requires, and where a project's data and hardware already
are. The image content, layering, and refresh behavior are the same on both hosts and are described
in `development-container.md`.

Riprap owns exporting the image and launching it on the execution host. Moving the file between
hosts is left to the tools a user's environment already provides, so the template acquires no
knowledge of a user's hosts, credentials, or network.

## Image Roles <!-- rq-96d0dd76 -->

- A build host runs Podman, builds the project's images, and can export the project image.
- An execution host runs Apptainer and launches a previously exported image. It builds nothing,
  contacts no release metadata, and requires no agent refresh state.
- The two roles may be the same machine. A host with both runtimes can build, export, and execute
  without transferring anything.
- Executing an image never rebuilds it. An execution host that cannot reach the network, cannot
  build, and holds no build key still launches a development container.

## Export <!-- rq-6b0c39ca -->

- `rr.sh --export-sif` builds the project's images by the ordinary build path and then writes a
  single-file Apptainer image. The build path is not shortened for export, so an exported image is a
  current project image rather than whichever image happened to be present.
- Export writes `.riprap/state/apptainer/riprap-<project-uuid>-project.sif`. The name is scoped by
  the canonical project UUID for the same reason build-host image names are: an image belonging to
  one project can never be mistaken for another project's, even on a shared filesystem holding many
  projects' images.
- Export leaves the build host's images, build key, and credential volumes unchanged, and starts no
  development container. It is a packaging operation, not a launch.
- The exported image carries the labels the project image carries, including the installed Claude,
  Codex, and OpenCode releases and the project UUID. An image on an execution host therefore reports
  what it contains and which project it belongs to without reference to the machine that built it or
  to any file that traveled alongside it.
- Export writes the image to a temporary path and moves it into place only after it is complete, so
  an interrupted or failed export never leaves a truncated image that a later launch would treat as
  usable.
- Export requires Apptainer on the build host, because producing the single-file image is Apptainer's
  own operation. A build host without Apptainer fails the export with an actionable message naming
  the missing runtime, and leaves no partial image.
- The Windows launcher reports that export is unavailable on the platform rather than failing inside
  a runtime, because Apptainer does not run on Windows.

## Project Correspondence <!-- rq-725e1140 -->

- The project image carries an `io.riprap.project-id` label recording the canonical project UUID it
  was built for.
- The execution-host launcher compares that label against `.riprap/state/project-id` in the workspace
  and refuses to launch when they differ, identifying both values. `.riprap/state/project-id` is
  committed project state, so it arrives with a clone of the repository while the image arrives
  separately; the two can disagree when a user transfers an image for the wrong project or an
  outdated one for a project whose identity was reset.
- An absent image fails the launch with a message naming the path the launcher expected, because the
  image is generated local state that version control does not carry and that a user moves
  deliberately.

## Execution-Host Launch <!-- rq-59469611 -->

- `rr.sh --run-sif` starts an interactive development container from the exported image.
- The launcher states the isolation it requires rather than accepting the runtime's defaults. It
  contains the container, so the invoking user's home directory is not exposed, and it supplies a
  clean environment, so the execution host's ambient environment does not reach the container. A
  cluster login environment commonly exports a large module-derived environment and holds the user's
  own credentials in their home directory; a runtime default that carried either into the container
  would silently widen the boundary that the development container exists to establish.
- The launcher mounts the project working directory at `/work` and makes it the working directory,
  matching the build host so that a project's own tooling and documentation describe one workspace
  path on every host.
- The image is presented read-only. The launcher supplies a writable temporary filesystem for paths
  outside the bind mounts, so tooling that writes scratch files works without the image itself being
  writable.
- The launcher requires no privilege mapping, user-namespace configuration, or setuid installation
  beyond what executing an image requires, because the image runs correctly as an arbitrary
  unprivileged user. Cluster administrators commonly disable unprivileged user namespaces, and
  support that depended on them would be unavailable exactly where it is most wanted.
- Launching is available on Unix hosts. The Windows launcher reports that execution is unavailable on
  the platform rather than failing inside a runtime.

## Credential State on an Execution Host <!-- rq-070cbb28 -->

- Claude, Codex, and OpenCode state lives in distinct directories beneath
  `.riprap/state/apptainer/credentials/`, each named for its agent, bound to that agent's
  configuration home inside the container. Apptainer addresses only the filesystem, so a directory
  is the mechanism available for state that must outlive a disposable container.
- The launcher creates missing directories with permissions that exclude group and other access, and
  creates the enclosing state directory the same way, so state is not readable by other users of a
  shared host by default.
- The directories hold credentials and session state only. Agent programs live in the image, so a
  bound directory never shadows an installed release.
- Generated `.gitignore` files reject the credential directories, which describe one user on one host
  rather than the project.
- The host's own agent configuration paths are never bound into the container, on an execution host
  as on a build host.
- `rr.sh --reset-agent-state <claude|codex|opencode|all>` removes the corresponding directories on an
  execution host, displaying what will be removed and requiring the same explicit confirmation the
  build host requires.
- A filesystem mechanism places credentials on whatever storage the project occupies. Cluster home
  and project filesystems are commonly shared, backed up, snapshotted, and readable by
  administrators, so generated documentation states this plainly and describes authenticating per
  session as the alternative for users who cannot accept it. Riprap does not claim a protection the
  filesystem does not provide.

## Run Options <!-- rq-f4a834db -->

- `.riprap/user/apptainer/run-options` supplies execution-runtime options beyond those the template
  always applies, for the same reasons and under the same rules as the build host's run options file
  described in `development-container.md`.
- The file is runtime-specific because execution-runtime options are. An option that grants GPU
  access to one runtime is not valid for the other, so a single shared file could hold an option
  correct for at most one of them.
- As delivered, every line is commentary, so a generated project enables no additional options. The
  commentary carries a commented example granting the container access to the host's GPUs, expressed
  in the options this runtime accepts.
- Each line that is neither blank nor a comment is exactly one runtime argument, passed verbatim. A
  launcher accepts a line only when it is a single token containing no whitespace and beginning with
  `-`, and otherwise fails the launch before a container starts, identifying the file and the
  offending line.
- The options are supplied after the workspace mount, credential bindings, containment and
  environment options, and working directory, so a runtime resolving a repeated option in favor of
  its last occurrence resolves it in the project's favor.
- A user's options are structurally validated and never interpreted. The launcher recognizes no
  particular option and grants no access of its own. The containment and environment options the
  launcher supplies restrict what the container reaches rather than extending it, so a project that
  enables an option never silently narrows the boundary the launcher established.

## Out of Scope <!-- rq-184a5bfb -->

- Transferring an image or a repository between hosts. A user moves files with the tools their
  environment provides, and Riprap holds no host, credential, or network configuration.
- Scheduling, submitting, or managing cluster workloads. An execution host launch provides an
  interactive session with the project's own tooling; workload managers, batch submission, and
  distributed execution belong to the generated project.
- Provisioning network access. Agents require network access to reach their model providers, and an
  execution host that denies it cannot run them. Riprap does not tunnel, proxy, or otherwise obtain
  that access.

## Feature Interface <!-- rq-8281e83b -->

- `rr.sh --export-sif`
  - Builds the project's images by the ordinary build path.
  - Writes a project-scoped single-file image under `.riprap/state/apptainer/`, atomically.
  - Stops with an actionable message, leaving no partial image, when the export runtime is absent.
  - Starts no development container.
- `rr.sh --run-sif`
  - Verifies that the exported image exists and records the workspace's project UUID.
  - Validates the execution-host run options before starting a container.
  - Starts an interactive development container that contains the invoking user's home directory,
    supplies a clean environment, mounts the workspace at `/work`, binds the project's credential
    directories, and presents the image read-only with writable scratch space.
- `rr.bat --export-sif` and `rr.bat --run-sif`
  - Report that the operation is unavailable on the platform and exit nonzero.

## Gherkin Scenarios <!-- rq-13f3d68a -->

```gherkin
Feature: Portable development image

  @rq-43e6dc0e
  Scenario: Export produces a project-scoped image without launching
    Given a generated project with a valid project UUID
    When the project launcher is asked to export a single-file image
    Then the project's images are built
    And a single-file image is written under ".riprap/state/apptainer/" whose name contains the
      project UUID
    And no development container starts

  @rq-eb4a9bc2
  Scenario: Export is atomic
    Given a generated project whose export fails while the image is being written
    When the export finishes
    Then no image exists at the destination path
    And the failure message identifies the export failure

  @rq-7a59cfaf
  Scenario: Export without the export runtime stops with an actionable message
    Given a build host on which the export runtime is not installed
    When the project launcher is asked to export a single-file image
    Then the export fails
    And the failure message names the missing runtime
    And no image is written

  @rq-d51385ac
  Scenario: An exported image records its releases and its project
    Given a generated project whose agent image labels record exact agent releases
    When the project launcher exports a single-file image
    Then the exported image's labels record the same Claude, Codex, and OpenCode releases
    And the exported image's labels record the project's canonical UUID

  @rq-5cd0d07b
  Scenario: Executing an exported image builds nothing
    Given an execution host with an exported image and no build runtime
    When the project launcher runs the exported image
    Then a development container starts
    And no image build is attempted
    And no release metadata is contacted

  @rq-fa98015e
  Scenario: An image belonging to another project is refused
    Given an exported image whose project-id label differs from ".riprap/state/project-id"
    When the project launcher runs the exported image
    Then launching fails
    And the failure message reports both the image's project UUID and the workspace's
    And no development container starts

  @rq-9c9e0a67
  Scenario: A missing exported image is reported by path
    Given a generated project with no exported image present
    When the project launcher runs the exported image
    Then launching fails
    And the failure message names the path the launcher expected
    And no development container starts

  @rq-92348db8
  Scenario: Execution isolates the invoking user's home directory and environment
    Given an execution host whose invoking user has a home directory and an ambient environment
    When the project launcher runs the exported image
    Then the runtime receives the option that contains the container
    And the runtime receives the option that supplies a clean environment
    And the runtime receives no bind of the invoking user's home directory

  @rq-cc89b043
  Scenario: Execution presents the workspace at the same path as a build host
    Given a generated project on an execution host
    When the project launcher runs the exported image
    Then the runtime receives the workspace bound at "/work"
    And the working directory is "/work"

  @rq-faa69453
  Scenario: Execution binds credential directories rather than host agent paths
    Given a generated project on an execution host
    When the project launcher runs the exported image
    Then the runtime receives a binding for each of the Claude, Codex, and OpenCode credential
      directories under ".riprap/state/apptainer/credentials/"
    And the runtime receives no binding of the host's own agent configuration paths

  @rq-41eb7773
  Scenario: Credential directories are created without group or other access
    Given an execution host with no credential directories for the project
    When the project launcher runs the exported image
    Then each agent's credential directory exists
    And no credential directory grants group or other access

  @rq-b7ad5dec
  Scenario: Credential state outlives a disposable container
    Given an execution host where a file was written to the Claude credential directory in an
      earlier session
    When the project launcher runs the exported image again
    Then the file remains readable at the same path inside the container

  @rq-cb7456b8
  Scenario: Credential directories are not committed
    Given a generated project on an execution host
    When Git ignore rules are evaluated
    Then the credential directories under ".riprap/state/apptainer/" are ignored

  @rq-372c5252
  Scenario: Reset removes only the selected agent's execution-host state
    Given an execution host with Claude, Codex, and OpenCode credential directories
    When the project resets its Codex state with explicit confirmation
    Then the Codex credential directory is removed
    And the Claude and OpenCode credential directories remain

  @rq-b42f7249
  Scenario: Reset requires explicit confirmation on an execution host
    Given an execution host with credential directories
    When the project resets agent state without a confirmation flag and without a terminal
    Then no credential directory is removed

  @rq-860c43c8
  Scenario: A generated project enables no execution-host run options
    Given a project is rendered from the Riprap template
    When the project launcher runs the exported image
    Then the runtime receives no arguments beyond the template-owned ones

  @rq-f88d5d7d
  Scenario: An enabled execution-host run option reaches the runtime
    Given an execution-host run options file whose only uncommented line is "--nv"
    When the project launcher runs the exported image
    Then the runtime receives the argument "--nv"
    And the project's option follows the template-owned arguments

  @rq-b3a587aa
  Scenario: An execution-host run option containing whitespace stops the launch
    Given an execution-host run options file whose only uncommented line contains a space
    When the project launcher runs the exported image
    Then launching fails
    And the failure message identifies the offending line
    And no container starts

  @rq-4a2d41bf
  Scenario: An execution-host run option that is not an option stops the launch
    Given an execution-host run options file whose only uncommented line does not begin with "-"
    When the project launcher runs the exported image
    Then launching fails
    And the failure message identifies the offending line
    And no container starts

  @rq-cd754953
  Scenario: An absent execution-host run options file enables no options
    Given a generated project whose execution-host run options file has been deleted
    When the project launcher runs the exported image
    Then launching succeeds
    And the runtime receives no arguments beyond the template-owned ones

  @rq-634af0c8
  Scenario: A template update preserves enabled execution-host run options
    Given a generated project whose execution-host run options file has been edited to enable an
      option
    When the project adopts a later template release with "copier update"
    Then the execution-host run options file retains the user's edit

  @rq-4a16eccf
  Scenario: The Windows launcher reports that export is unavailable
    Given a generated project on Windows
    When the Windows launcher is asked to export a single-file image
    Then it exits nonzero
    And its message states that the operation is unavailable on the platform
    And no image is written

  @rq-73fc74a3
  Scenario: The Windows launcher reports that execution is unavailable
    Given a generated project on Windows
    When the Windows launcher is asked to run an exported image
    Then it exits nonzero
    And its message states that the operation is unavailable on the platform
    And no development container starts
```
