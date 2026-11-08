#!/bin/bash
set -e

USER=zerotier
REPO=ZeroTierOne
DOCKER_IMAGE="fullyautomaticio/zerotier-planet"

# 只取正式 release（x.y.z）
latest_tag=$(curl -s "https://api.github.com/repos/$USER/$REPO/releases" | jq -r '.[] | select(.prerelease == false and .draft == false) | .tag_name' | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" | sort -V | tail -n 1)
latest_docker_tag=$(curl -s "https://hub.docker.com/v2/repositories/${DOCKER_IMAGE}/tags/?page_size=100" | jq -r '.results[].name' | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" | sort -V | tail -n 1)

if [ -z "$latest_tag" ]; then
    echo "Failed to get latest ZeroTierOne release"
    exit 1
fi

if [ "$latest_tag" == "$latest_docker_tag" ]; then
    echo "No new version found"
    exit 0
fi

echo "Latest tag for $USER/$REPO is: $latest_tag"
docker buildx build --platform linux/arm64,linux/amd64 \
    --build-arg TAG="${latest_tag}" \
    -t "${DOCKER_IMAGE}:latest" \
    -t "${DOCKER_IMAGE}:${latest_tag}" \
    --push .
