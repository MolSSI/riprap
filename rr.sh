#!/bin/sh
# Riprap-managed adapter. The canonical launcher lives under .riprap/managed.
exec .riprap/managed/launch/rr.sh "$@"
