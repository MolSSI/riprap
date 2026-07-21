#!/bin/sh
# Export a built project image to a single-file Apptainer image for execution on a host that cannot
# build one. Producing the single-file image is Apptainer's own operation, so this runs on the build
# host after the ordinary build path has produced the project image.

set -eu

project_id="${1:?project UUID is required}"
project_image="${2:?project image is required}"

sif_dir=".riprap/state/apptainer"
dest="${sif_dir}/riprap-${project_id}-project.sif"

fail() {
    printf 'Riprap: %s\n' "$1" >&2
    exit 1
}

command -v apptainer >/dev/null 2>&1 || \
    fail 'Apptainer is required to export a single-file image, but was not found on PATH'

mkdir -p "$sif_dir"

# Write to temporary paths and move the finished image into place only after it is complete, so an
# interrupted or failed export never leaves a truncated image a later launch would treat as usable.
work_dir="$(mktemp -d "${sif_dir}/export.XXXXXX")"
tmp_sif="${dest}.tmp.$$"
cleanup() { rm -rf "$work_dir" "$tmp_sif"; }
trap cleanup EXIT HUP INT TERM

oci_archive="${work_dir}/image.oci-archive"
# Hand the Podman-built image to Apptainer through an OCI archive, which carries the image's labels
# so the exported image reports its agent releases and the project it belongs to.
podman save --format oci-archive -o "$oci_archive" "$project_image" || \
    fail 'could not export the project image from Podman'
apptainer build "$tmp_sif" "oci-archive:${oci_archive}" || \
    fail 'Apptainer could not build the single-file image'

mv "$tmp_sif" "$dest"
trap - EXIT HUP INT TERM
cleanup
printf 'Riprap: exported %s\n' "$dest"
