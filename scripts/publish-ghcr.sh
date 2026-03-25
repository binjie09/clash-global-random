#!/bin/sh
set -eu

OWNER="${OWNER:-}"
IMAGE_NAME="${IMAGE_NAME:-clash-global-random}"
REGISTRY="${REGISTRY:-ghcr.io}"
TAG="${TAG:-latest}"
USERNAME="${USERNAME:-${OWNER}}"
FULL_IMAGE="${REGISTRY}/${OWNER}/${IMAGE_NAME}:${TAG}"

if [ -z "$OWNER" ]; then
  echo "OWNER is required, for example: OWNER=binjie09" >&2
  exit 1
fi

if [ -n "${GHCR_TOKEN:-}" ]; then
  printf '%s' "$GHCR_TOKEN" | docker login "$REGISTRY" -u "$USERNAME" --password-stdin
fi

docker build -t "$FULL_IMAGE" .
docker push "$FULL_IMAGE"
