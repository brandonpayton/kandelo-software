#!/usr/bin/env bash
set -euo pipefail

SOFTWARE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KANDELO_ROOT=""
PACKAGE_SELECTION="all"
TARGET_TAG=""
REPOSITORY="${GITHUB_REPOSITORY:-brandonpayton/kandelo-software}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --software-root) SOFTWARE_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --kandelo-root) KANDELO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --packages) PACKAGE_SELECTION="$2"; shift 2 ;;
    --target-tag) TARGET_TAG="$2"; shift 2 ;;
    --repo) REPOSITORY="$2"; shift 2 ;;
    *) echo "build-and-publish: unknown flag $1" >&2; exit 2 ;;
  esac
done

if [ -z "$KANDELO_ROOT" ]; then
  echo "build-and-publish: --kandelo-root is required" >&2
  exit 2
fi

args=(
  --package-source-root "$SOFTWARE_ROOT"
  --kandelo-root "$KANDELO_ROOT"
  --packages "$PACKAGE_SELECTION"
  --repo "$REPOSITORY"
)
if [ -n "$TARGET_TAG" ]; then
  args+=(--target-tag "$TARGET_TAG")
fi

exec "$KANDELO_ROOT/scripts/publish-package-source.sh" "${args[@]}"
