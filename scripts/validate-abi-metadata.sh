#!/usr/bin/env bash
set -euo pipefail

SOFTWARE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KANDELO_ROOT=""
PACKAGE_SELECTION="all"
TARGET_TAG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --software-root) SOFTWARE_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --kandelo-root) KANDELO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --packages) PACKAGE_SELECTION="$2"; shift 2 ;;
    --target-tag) TARGET_TAG="$2"; shift 2 ;;
    *) echo "validate-abi-metadata: unknown flag $1" >&2; exit 2 ;;
  esac
done

if [ -z "$KANDELO_ROOT" ]; then
  echo "validate-abi-metadata: --kandelo-root is required" >&2
  exit 2
fi

ABI="$(grep -oE 'ABI_VERSION: u32 = [0-9]+' "$KANDELO_ROOT/crates/shared/src/lib.rs" | awk '{print $4}' || true)"
[ -n "$ABI" ] || {
  echo "validate-abi-metadata: could not read Kandelo ABI_VERSION" >&2
  exit 2
}

TARGET_TAG="${TARGET_TAG:-binaries-abi-v${ABI}}"
TARGET_ABI="${TARGET_TAG#binaries-abi-v}"
if [ "$TARGET_ABI" = "$TARGET_TAG" ] || ! [[ "$TARGET_ABI" =~ ^[0-9]+$ ]]; then
  echo "validate-abi-metadata: target release must be binaries-abi-v<N>, got $TARGET_TAG" >&2
  exit 2
fi
if [ "$TARGET_ABI" != "$ABI" ]; then
  echo "validate-abi-metadata: target release $TARGET_TAG is for ABI $TARGET_ABI, but Kandelo is ABI $ABI" >&2
  exit 2
fi

want_pkg() {
  local pkg="$1"
  if [ "$PACKAGE_SELECTION" = "all" ] || [ -z "$PACKAGE_SELECTION" ]; then
    return 0
  fi
  local normalized
  normalized="$(printf '%s' "$PACKAGE_SELECTION" | tr ',' ' ')"
  [[ " $normalized " == *" $pkg "* ]]
}

validate_selection() {
  local normalized requested known
  normalized="$(printf '%s' "$PACKAGE_SELECTION" | tr ',' ' ')"

  [ "$PACKAGE_SELECTION" != "all" ] || return 0
  [ -n "$PACKAGE_SELECTION" ] || return 0

  for requested in $normalized; do
    known=0
    for pkg in "${ordered[@]}"; do
      if [ "$pkg" = "$requested" ]; then
        known=1
        break
      fi
    done
    if [ "$known" -eq 0 ]; then
      echo "validate-abi-metadata: unknown package in selection: $requested" >&2
      return 1
    fi
  done
}

read_gallery_tag() {
  local file="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.release_tag // empty' "$file"
  else
    sed -nE 's/^[[:space:]]*"release_tag"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$file" | head -1
  fi
}

mapfile -t ordered <"$SOFTWARE_ROOT/packages.txt"

mismatch=0
if ! validate_selection; then
  mismatch=1
fi

for pkg in "${ordered[@]}"; do
  [ -n "$pkg" ] || continue
  want_pkg "$pkg" || continue

  pkg_dir="$SOFTWARE_ROOT/packages/$pkg"
  if [ ! -f "$pkg_dir/package.toml" ]; then
    echo "validate-abi-metadata: package recipe missing: $pkg_dir/package.toml" >&2
    mismatch=1
    continue
  fi

  package_abi="$(sed -nE 's/^[[:space:]]*kernel_abi[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$pkg_dir/package.toml" | head -1)"
  if [ "$package_abi" != "$ABI" ]; then
    echo "validate-abi-metadata: $pkg/package.toml has kernel_abi=${package_abi:-missing}; expected $ABI" >&2
    mismatch=1
  fi
done

if [ -f "$SOFTWARE_ROOT/gallery.json" ]; then
  gallery_tag="$(read_gallery_tag "$SOFTWARE_ROOT/gallery.json")"
  if [ "$gallery_tag" != "$TARGET_TAG" ]; then
    echo "validate-abi-metadata: gallery.json has release_tag=${gallery_tag:-missing}; expected $TARGET_TAG" >&2
    mismatch=1
  fi
fi

if [ "$mismatch" -ne 0 ]; then
  echo "validate-abi-metadata: ABI metadata is stale for Kandelo ABI $ABI" >&2
  exit 1
fi

echo "validate-abi-metadata: Kandelo ABI $ABI metadata OK for $TARGET_TAG"
