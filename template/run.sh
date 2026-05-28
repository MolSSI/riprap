#!/bin/sh

IMAGE=$(cat .guardrails/podman/image_name)

podman build -t "$IMAGE" .

bash .guardrails/interface.sh "$IMAGE"
