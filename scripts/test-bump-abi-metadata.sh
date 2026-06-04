#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kandelo-abi-bump-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

cp -R "$REPO_ROOT/packages" "$TMP_ROOT/packages"
cp "$REPO_ROOT/gallery.json" "$TMP_ROOT/gallery.json"
mkdir -p "$TMP_ROOT/docs"
cp "$REPO_ROOT/docs/maintaining.md" "$TMP_ROOT/docs/maintaining.md"

"$REPO_ROOT/scripts/bump-abi-metadata.sh" --software-root "$TMP_ROOT" --abi 11 >/dev/null
"$REPO_ROOT/scripts/bump-abi-metadata.sh" --software-root "$TMP_ROOT" --abi 13 >/dev/null

bad=0
for package_file in "$TMP_ROOT"/packages/*/package.toml; do
  if ! grep -Eq '^kernel_abi = 13$' "$package_file"; then
    echo "test-bump-abi-metadata: expected kernel_abi = 13 in $package_file" >&2
    bad=1
  fi
done

gallery_tag="$(jq -r '.release_tag // empty' "$TMP_ROOT/gallery.json")"
if [ "$gallery_tag" != "binaries-abi-v13" ]; then
  echo "test-bump-abi-metadata: expected gallery release_tag binaries-abi-v13, got ${gallery_tag:-missing}" >&2
  bad=1
fi

if ! grep -q 'set targets ABI 13' "$TMP_ROOT/docs/maintaining.md"; then
  echo "test-bump-abi-metadata: expected docs to target ABI 13" >&2
  bad=1
fi

snapshot() {
  find "$TMP_ROOT" -type f -print | sort | while IFS= read -r file; do
    shasum "$file"
  done
}

before="$(snapshot)"
"$REPO_ROOT/scripts/bump-abi-metadata.sh" --software-root "$TMP_ROOT" --abi 13 >/dev/null
after="$(snapshot)"
if [ "$before" != "$after" ]; then
  echo "test-bump-abi-metadata: ABI 13 bump is not idempotent" >&2
  bad=1
fi

if [ "$bad" -ne 0 ]; then
  exit 1
fi

echo "test-bump-abi-metadata: ABI 11 to ABI 13 bump OK"
