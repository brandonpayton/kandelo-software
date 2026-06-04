#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <kandelo-root>" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

SOFTWARE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KANDELO_ROOT="$(cd "$1" && pwd)"
REGISTRY_ROOT="$KANDELO_ROOT/packages/registry"

[ -d "$REGISTRY_ROOT" ] || {
  echo "sync-packages: $KANDELO_ROOT does not look like a Kandelo checkout" >&2
  exit 2
}

for pkg_dir in "$SOFTWARE_ROOT"/packages/*; do
  [ -d "$pkg_dir" ] || continue
  pkg="$(basename "$pkg_dir")"
  dest="$REGISTRY_ROOT/$pkg"
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -R "$pkg_dir"/. "$dest"/
  find "$dest" -name 'build-*.sh' -exec chmod +x {} +
  echo "sync-packages: overlaid $pkg"
done
