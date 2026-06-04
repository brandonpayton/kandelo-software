#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="brandonpayton/wasm-posix-kernel"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPOSITORY="$2"; shift 2 ;;
    *) echo "latest-kandelo-abi: unknown flag $1" >&2; exit 2 ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "latest-kandelo-abi: gh is required" >&2
  exit 2
fi

abi="$(
  gh api --paginate "/repos/$REPOSITORY/releases" \
    --jq '.[] | select((.draft | not) and (.prerelease | not)) | .tag_name' \
    | sed -nE 's/^binaries-abi-v([0-9]+)$/\1/p' \
    | sort -n \
    | tail -1
)"

if [ -z "$abi" ]; then
  echo "latest-kandelo-abi: no durable binaries-abi-v<N> release found in $REPOSITORY" >&2
  exit 1
fi

echo "$abi"
