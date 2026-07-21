#!/bin/sh

set -eu

source_file=${1:-Containerfile}
output_file=${2:-.riprap/state/container/Project.Containerfile}

mkdir -p "$(dirname "$output_file")"
awk '
  $0 == "FROM localhost/riprap-agent:latest" {
    print "ARG RIPRAP_AGENT_IMAGE"
    print "FROM ${RIPRAP_AGENT_IMAGE}"
    next
  }
  { print }
' "$source_file" > "$output_file"

