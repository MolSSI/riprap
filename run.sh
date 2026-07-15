#!/bin/sh

IMAGE=$(cat .guardrails/podman/image_name)

podman build -t guardrails-base:latest .guardrails/podman
podman build -t "$IMAGE" .

bash .guardrails/interface.sh "$IMAGE"
