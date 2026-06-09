#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kandelo-publish-inputs-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

cp "$REPO_ROOT/gallery.json" "$TMP_ROOT/gallery.json"

run_case() {
  local name="$1"
  local expected_ref="$2"
  local expected_packages="$3"
  local expected_tag="$4"
  shift 4

  local output_file="$TMP_ROOT/$name.outputs"
  GITHUB_OUTPUT="$output_file" \
    "$REPO_ROOT/scripts/resolve-publish-inputs.sh" \
      --software-root "$TMP_ROOT" \
      "$@" >/dev/null

  local actual_ref actual_packages actual_tag
  actual_ref="$(sed -nE 's/^kandelo_ref=(.*)$/\1/p' "$output_file")"
  actual_packages="$(sed -nE 's/^packages=(.*)$/\1/p' "$output_file")"
  actual_tag="$(sed -nE 's/^release_tag=(.*)$/\1/p' "$output_file")"

  if [ "$actual_ref" != "$expected_ref" ]; then
    echo "test-publish-inputs: $name kandelo_ref=$actual_ref; expected $expected_ref" >&2
    return 1
  fi
  if [ "$actual_packages" != "$expected_packages" ]; then
    echo "test-publish-inputs: $name packages=$actual_packages; expected $expected_packages" >&2
    return 1
  fi
  if [ "$actual_tag" != "$expected_tag" ]; then
    echo "test-publish-inputs: $name release_tag=$actual_tag; expected $expected_tag" >&2
    return 1
  fi
}

gallery_tag="$(jq -r '.release_tag // empty' "$TMP_ROOT/gallery.json")"

run_case default "$gallery_tag" all "$gallery_tag"
run_case explicit-main main redis "" --kandelo-ref main --packages redis --release-tag ""
run_case explicit-tag binaries-abi-v14 all binaries-abi-v14 --release-tag binaries-abi-v14

echo "test-publish-inputs: publish input resolution OK"
