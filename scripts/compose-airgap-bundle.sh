#!/usr/bin/env bash
# Build an air-gap bundle for the Docker Compose deployment: every image the
# compose file uses (all profiles) saved into one tarball, plus the deployment
# files, that you can carry into a network with no internet.
#
#   scripts/compose-airgap-bundle.sh [--platform linux/amd64] [-o OUT_DIR]
#
# Run it on an internet-connected host, in a copy of this repository whose `.env`
# already holds the versions you were given (CALLMAN_VERSION, CALLMAN_ADMIN_VERSION),
# after `docker login ghcr.io`. It reads the image list from Compose itself, so it
# cannot drift from docker-compose.yml.
#
# On the isolated host:  tar xzf callman-airgap-<version>.tar.gz && ./scripts/compose-airgap-load.sh
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
platform="linux/amd64"
out_dir="$here/dist"

while [ $# -gt 0 ]; do
  case "$1" in
    --platform) platform="$2"; shift 2 ;;
    -o|--out) out_dir="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
[ -f "$here/.env" ] || { echo "no .env in $here — copy .env.example and set CALLMAN_VERSION / CALLMAN_ADMIN_VERSION first" >&2; exit 1; }

cd "$here"
images=()
while IFS= read -r line; do [ -n "$line" ] && images+=("$line"); done < <(docker compose --profile '*' config --images | sort -u)
[ "${#images[@]}" -gt 0 ] || { echo "compose lists no images" >&2; exit 1; }
for image in "${images[@]}"; do
  case "$image" in *"<CHANGE_ME"*) echo "an image still has a placeholder tag ($image) — set the versions in .env" >&2; exit 1 ;; esac
done

version="$(grep -E '^[[:space:]]*CALLMAN_VERSION=' .env | tail -n1 | cut -d= -f2- | tr -d '"'"'"' ')"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$out_dir" "$stage/callman-onprem"

echo "==> ${#images[@]} images, platform ${platform}"
for image in "${images[@]}"; do
  echo "==> pull ${image}"
  docker pull --platform "$platform" "$image" >/dev/null
done

echo "==> save images.tar"
docker save "${images[@]}" -o "$stage/callman-onprem/images.tar"

# Deployment files (never .env: it holds secrets and is created on the target).
tar -C "$here" --exclude='./dist' --exclude='./.env' --exclude='./.git' -cf - . | tar -C "$stage/callman-onprem" -xf -
printf '%s\n' "${images[@]}" > "$stage/callman-onprem/images.txt"

bundle="$out_dir/callman-airgap-${version:-unknown}.tar.gz"
tar -C "$stage" -czf "$bundle" callman-onprem
( cd "$out_dir" && shasum -a 256 "$(basename "$bundle")" > "$(basename "$bundle").sha256" )
echo "==> $bundle"
echo "    sha256: $(cut -d' ' -f1 "${bundle}.sha256")"
