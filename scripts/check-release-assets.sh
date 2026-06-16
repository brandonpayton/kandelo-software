#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="${GITHUB_REPOSITORY:-}"
RELEASE_TAG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPOSITORY="$2"; shift 2 ;;
    --release-tag) RELEASE_TAG="$2"; shift 2 ;;
    *) echo "check-release-assets: unknown flag $1" >&2; exit 2 ;;
  esac
done

if [ -z "$REPOSITORY" ]; then
  echo "check-release-assets: --repo is required" >&2
  exit 2
fi
if [ -z "$RELEASE_TAG" ]; then
  echo "check-release-assets: --release-tag is required" >&2
  exit 2
fi

release_exists=false
index_present=false
gallery_present=false

if assets_json="$(gh release view "$RELEASE_TAG" --repo "$REPOSITORY" --json assets --jq '[.assets[].name]' 2>/dev/null)"; then
  release_exists=true
  if jq -e 'index("index.toml")' <<<"$assets_json" >/dev/null; then
    index_present=true
  fi
  if jq -e 'index("gallery.json")' <<<"$assets_json" >/dev/null; then
    gallery_present=true
  fi
else
  assets_json='[]'
fi

release_complete=false
if [ "$release_exists" = true ] && [ "$index_present" = true ] && [ "$gallery_present" = true ]; then
  release_complete=true
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "release_exists=$release_exists"
    echo "index_present=$index_present"
    echo "gallery_present=$gallery_present"
    echo "release_complete=$release_complete"
  } >> "$GITHUB_OUTPUT"
fi

echo "check-release-assets: $REPOSITORY/$RELEASE_TAG exists=$release_exists index.toml=$index_present gallery.json=$gallery_present"
