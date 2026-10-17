#!/usr/bin/env bash
# Load the images from a Compose air-gap bundle into this host's Docker daemon.
# The images keep their original names, so docker-compose.yml works unchanged.
#
#   ./scripts/compose-airgap-load.sh
#
# Run from the unpacked bundle (images.tar sits next to the scripts folder).
# To serve the images from your own registry instead, retag and push them
# yourself (images.txt lists the names) and change the three `image:` lines in
# docker-compose.yml to match.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
[ -f "$here/images.tar" ] || { echo "images.tar not found in $here — run this from the unpacked bundle" >&2; exit 1; }

echo "==> docker load"
docker load -i "$here/images.tar"
echo "==> done. Next: cp .env.example .env, edit it, ./scripts/preflight.sh, docker compose up -d"
