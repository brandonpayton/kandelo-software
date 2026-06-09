#!/usr/bin/env bash
set -euo pipefail

SOFTWARE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KANDELO_REF=""
PACKAGE_SELECTION="all"
RELEASE_TAG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --software-root) SOFTWARE_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --kandelo-ref) KANDELO_REF="$2"; shift 2 ;;
    --packages) PACKAGE_SELECTION="$2"; shift 2 ;;
    --release-tag) RELEASE_TAG="$2"; shift 2 ;;
    *) echo "resolve-publish-inputs: unknown flag $1" >&2; exit 2 ;;
  esac
done

read_gallery_tag() {
  local file="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.release_tag // empty' "$file"
  else
    sed -nE 's/^[[:space:]]*"release_tag"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$file" | head -1
  fi
}

gallery_tag=""
if [ -f "$SOFTWARE_ROOT/gallery.json" ]; then
  gallery_tag="$(read_gallery_tag "$SOFTWARE_ROOT/gallery.json")"
fi

if [ -z "$KANDELO_REF" ]; then
  if [ -z "$RELEASE_TAG" ]; then
    RELEASE_TAG="$gallery_tag"
  fi
  KANDELO_REF="$RELEASE_TAG"
fi

if [ -z "$KANDELO_REF" ]; then
  echo "resolve-publish-inputs: no Kandelo ref provided and gallery.json has no release_tag" >&2
  exit 2
fi

if [ -n "$RELEASE_TAG" ] && ! [[ "$RELEASE_TAG" =~ ^binaries-abi-v[0-9]+$ ]]; then
  echo "resolve-publish-inputs: release tag must be binaries-abi-v<N>, got $RELEASE_TAG" >&2
  exit 2
fi

PACKAGE_SELECTION="${PACKAGE_SELECTION:-all}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "kandelo_ref=$KANDELO_REF"
    echo "packages=$PACKAGE_SELECTION"
    echo "release_tag=$RELEASE_TAG"
  } >> "$GITHUB_OUTPUT"
fi

echo "resolve-publish-inputs: kandelo-ref=$KANDELO_REF"
echo "resolve-publish-inputs: packages=$PACKAGE_SELECTION"
echo "resolve-publish-inputs: release-tag=${RELEASE_TAG:-<derived from Kandelo ABI>}"
