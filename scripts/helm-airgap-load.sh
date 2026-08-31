#!/usr/bin/env bash
# Load an airgap bundle into an internal registry (run INSIDE the customer
# network, from the extracted bundle directory):
#
#   tar -xzf callman-helm-airgap-<version>.tar.gz -C bundle && cd bundle
#   ./helm-airgap-load.sh registry.bank.local
#
# Retag convention matches the chart's global.imageRegistry override: the
# source registry host is replaced, the repository path is kept, and plain
# Docker Hub names gain the library/ prefix.
set -euo pipefail

registry="${1:?usage: helm-airgap-load.sh <internal-registry> (must be docker-logged-in)}"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
[ -f images.tar ] || { echo "images.tar not found — run from the extracted bundle directory" >&2; exit 1; }

shasum -a 256 -c checksums.sha256

echo "==> docker load"
docker load -i images.tar

chart_tgz="$(ls callman-*.tgz | head -1)"

while read -r image; do
  image="${image#"  - "}"
  [ -n "$image" ] || continue
  repo_path="$image"
  case "$image" in
    *.*/*|*:*/*) repo_path="${image#*/}" ;;      # strip source registry host
    */*) ;;                                       # user/name stays as-is
    *) repo_path="library/${image}" ;;            # docker hub official image
  esac
  target="${registry}/${repo_path}"
  echo "==> ${image} -> ${target}"
  docker tag "$image" "$target"
  docker push "$target" >/dev/null
done < <(grep '^  - ' manifest.yaml)

cat <<EOF

Images pushed. Install with:

  helm install callman ./${chart_tgz} \\
    --namespace callman --create-namespace \\
    --set global.imageRegistry=${registry} \\
    -f your-values.yaml

See docs/HELM-INSTALL.md for the values reference and secret setup.
EOF
