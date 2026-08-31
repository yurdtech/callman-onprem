#!/usr/bin/env bash
# Build an airgap bundle for the Helm deployment: chart package + every image
# the chart references, saved into one tarball a bank can carry inside.
#
#   scripts/helm-airgap-bundle.sh [--platform linux/amd64] [-o OUT_DIR]
#
# Run on an internet-connected host that is logged in to ghcr.io
# (docker login ghcr.io -u yurdtech). Versions are read from the chart:
# appVersion (= CALLMAN_VERSION) and admin.image.tag (= CALLMAN_ADMIN_VERSION).
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
chart_dir="$here/helm/callman"
platform="linux/amd64"
out_dir="$here/dist"

while [ $# -gt 0 ]; do
  case "$1" in
    --platform) platform="$2"; shift 2 ;;
    -o|--out) out_dir="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

command -v helm >/dev/null || { echo "helm is required" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

chart_version="$(awk '/^version:/ {print $2}' "$chart_dir/Chart.yaml")"
app_version="$(awk '/^appVersion:/ {gsub(/"/,"",$2); print $2}' "$chart_dir/Chart.yaml")"
admin_version="$(awk '/tag:/ && seen {gsub(/"/,"",$2); print $2; exit} /^admin:/ {seen=1}' "$chart_dir/values.yaml")"

images=(
  "ghcr.io/yurdtech/callman-backend:${app_version}"
  "ghcr.io/yurdtech/callman-ui-runner:${app_version}"
  "ghcr.io/yurdtech/callman-onprem-admin:${admin_version}"
  "mongo:7"
  "redis:7-alpine"
)

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$out_dir"

echo "==> chart callman-${chart_version} (app ${app_version}, admin ${admin_version}), platform ${platform}"

helm package "$chart_dir" -d "$stage" >/dev/null

for image in "${images[@]}"; do
  echo "==> pull ${image}"
  docker pull --platform "$platform" "$image" >/dev/null
done

echo "==> save images.tar"
docker save "${images[@]}" -o "$stage/images.tar"

{
  echo "chart: callman-${chart_version}.tgz"
  echo "platform: ${platform}"
  echo "images:"
  for image in "${images[@]}"; do echo "  - ${image}"; done
} > "$stage/manifest.yaml"

cp "$here/scripts/helm-airgap-load.sh" "$stage/"
(cd "$stage" && shasum -a 256 images.tar "callman-${chart_version}.tgz" > checksums.sha256)

bundle="$out_dir/callman-helm-airgap-${app_version}.tar.gz"
tar -czf "$bundle" -C "$stage" .
echo "==> $bundle"
echo "Hand the bundle to the customer; inside their network they run helm-airgap-load.sh (see docs/HELM-INSTALL.md)."
