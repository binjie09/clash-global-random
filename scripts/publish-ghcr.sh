#!/bin/sh
set -eu

OWNER="${OWNER:-binjie09}"
IMAGE_NAME="${IMAGE_NAME:-clash-global-random}"
REGISTRY="${REGISTRY:-ghcr.io}"
TAG="${TAG:-latest}"
USERNAME="${USERNAME:-${OWNER}}"
FULL_IMAGE="${REGISTRY}/${OWNER}/${IMAGE_NAME}:${TAG}"

if [ -n "${GHCR_TOKEN:-}" ]; then
  printf '%s' "$GHCR_TOKEN" | docker login "$REGISTRY" -u "$USERNAME" --password-stdin
fi

docker build -t "$FULL_IMAGE" .
docker push "$FULL_IMAGE"
