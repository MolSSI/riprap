#!/bin/sh
# Launch an interactive development container on an execution host from a previously exported
# single-file image. This host builds nothing: it verifies the image belongs to this project, binds
# the workspace and the project's credential directories, and states the isolation it requires
# rather than accepting the runtime's defaults.

set -eu

project_id="${1:?project UUID is required}"

sif_dir=".riprap/state/apptainer"
sif_image="${sif_dir}/riprap-${project_id}-project.sif"
credentials_dir="${sif_dir}/credentials"
run_options_file=".riprap/user/apptainer/run-options"

fail() {
    printf 'Riprap: %s\n' "$1" >&2
    exit 1
}

# The image is generated local state that version control does not carry and a user moves
# deliberately, so an absent image names the path the launcher expected.
[ -f "$sif_image" ] || fail "no exported image at ${sif_image}; build one on a build host with 'rr.sh --export-sif' and copy it here"

# The committed project identity arrives with a clone while the image arrives separately, so the
# two can disagree when a user transfers an image for the wrong or an outdated project. The label
# is authoritative about which project an image was built for.
image_project_id="$(apptainer inspect --json "$sif_image" 2>/dev/null \
    | sed -n 's/.*"io.riprap.project-id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
[ -n "$image_project_id" ] || fail "cannot read the project identity of ${sif_image}"
if [ "$image_project_id" != "$project_id" ]; then
    fail "image belongs to project ${image_project_id}, but this workspace is project ${project_id}"
fi

# Apptainer addresses only the filesystem, so credentials persist in directories rather than in a
# managed volume. A umask that excludes group and other access keeps state from being readable by
# other users of a shared host by default.
umask 077
mkdir -p "$credentials_dir"
for agent in claude codex opencode; do
    mkdir -p "${credentials_dir}/${agent}"
done

# Validate the project's execution-runtime options with the same shared helper the build host uses,
# so a defect is reported identically. The options are supplied after the template-owned arguments,
# so a runtime resolving a repeated option last resolves it in the project's favor.
. .riprap/managed/launch/run-options.sh
options="$(emit_run_options "$run_options_file")" || exit 1
set --
IFS='
'
for option in $options; do set -- "$@" "$option"; done
unset IFS

# --containall isolates the invoking user's home directory and default binds; --no-home prevents
# Apptainer from replacing the image-owned HOME with an empty containment mount, so programs
# installed beneath it remain available. --cleanenv keeps the execution host's ambient environment
# out of the container; --writable-tmpfs supplies scratch space so the read-only image starts. Each
# credential directory binds to its agent's configuration home under the image-owned home directory,
# holding credentials and session state only. The host's own agent configuration paths are never
# bound.
#
# HOME must be the image-owned home so tools resolve their state through it -- the language
# toolchain, each agent's configuration home and cache -- rather than an account home that holds
# none of the image's installation. Apptainer will not take HOME from the environment: an
# --env HOME (APPTAINERENV_HOME) is refused with "Overriding HOME environment variable ... is not
# permitted" and ignored, and its --home flag bind-mounts a host directory over the target, which
# would hide the toolchain installed beneath the image-owned home. So HOME is exported by the
# command the container runs -- after Apptainer's own startup -- which the interactive shell and
# everything launched from it inherit. exec (rather than shell) is used because only a run form that
# takes a command can carry that env assignment.
exec apptainer exec \
    --containall \
    --no-home \
    --cleanenv \
    --writable-tmpfs \
    --pwd /work \
    --bind "$(pwd):/work" \
    --bind "$(pwd)/${credentials_dir}/claude:/opt/riprap/home/.claude" \
    --bind "$(pwd)/${credentials_dir}/codex:/opt/riprap/home/.codex" \
    --bind "$(pwd)/${credentials_dir}/opencode:/opt/riprap/home/.opencode" \
    --env CLAUDE_CONFIG_DIR=/opt/riprap/home/.claude \
    "$@" \
    "$sif_image" \
    env HOME=/opt/riprap/home bash
