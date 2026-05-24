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

if [ -d "$KANDELO_ROOT/packages/registry" ]; then
  PRIMARY_ROOT="$KANDELO_ROOT/packages/registry"
  COMPAT_ROOT="$KANDELO_ROOT/examples/libs"
elif [ -d "$KANDELO_ROOT/examples/libs" ]; then
  PRIMARY_ROOT="$KANDELO_ROOT/examples/libs"
  COMPAT_ROOT=""
else
  echo "sync-packages: $KANDELO_ROOT does not look like a Kandelo checkout" >&2
  exit 2
fi

for pkg_dir in "$SOFTWARE_ROOT"/packages/*; do
  [ -d "$pkg_dir" ] || continue
  [ -f "$pkg_dir/package.toml" ] || continue
  pkg="$(basename "$pkg_dir")"
  dest="$PRIMARY_ROOT/$pkg"
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -R "$pkg_dir"/. "$dest"/
  find "$dest" -name 'build-*.sh' -exec chmod +x {} +
  echo "sync-packages: overlaid $pkg -> ${dest#$KANDELO_ROOT/}"

  if [ -n "$COMPAT_ROOT" ]; then
    compat_dest="$COMPAT_ROOT/$pkg"
    rm -rf "$compat_dest"
    mkdir -p "$compat_dest"
    cp -R "$pkg_dir"/. "$compat_dest"/
    find "$compat_dest" -name 'build-*.sh' -exec chmod +x {} +
    echo "sync-packages: overlaid $pkg -> ${compat_dest#$KANDELO_ROOT/}"
  fi
done
