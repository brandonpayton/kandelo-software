#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kandelo-release-assets-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${GH_RELEASE_FIXTURE:-missing}" in
  missing)
    exit 1
    ;;
  index-only)
    printf '%s\n' '["index.toml"]'
    ;;
  gallery-only)
    printf '%s\n' '["gallery.json"]'
    ;;
  complete)
    printf '%s\n' '["index.toml","gallery.json","redis-0.0.0-abi13-wasm32-deadbeef.tar.zst"]'
    ;;
  *)
    echo "unknown GH_RELEASE_FIXTURE=$GH_RELEASE_FIXTURE" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/gh"

run_case() {
  local name="$1"
  local expected_exists="$2"
  local expected_index="$3"
  local expected_gallery="$4"
  local expected_complete="$5"
  local output_file="$TMP_ROOT/$name.outputs"

  PATH="$TMP_ROOT/bin:$PATH" \
  GH_RELEASE_FIXTURE="$name" \
  GITHUB_OUTPUT="$output_file" \
    "$REPO_ROOT/scripts/check-release-assets.sh" \
      --repo example/kandelo-software \
      --release-tag binaries-abi-v13 >/dev/null

  local actual_exists actual_index actual_gallery actual_complete
  actual_exists="$(sed -nE 's/^release_exists=(.*)$/\1/p' "$output_file")"
  actual_index="$(sed -nE 's/^index_present=(.*)$/\1/p' "$output_file")"
  actual_gallery="$(sed -nE 's/^gallery_present=(.*)$/\1/p' "$output_file")"
  actual_complete="$(sed -nE 's/^release_complete=(.*)$/\1/p' "$output_file")"

  if [ "$actual_exists" != "$expected_exists" ]; then
    echo "test-release-assets: $name release_exists=$actual_exists; expected $expected_exists" >&2
    return 1
  fi
  if [ "$actual_index" != "$expected_index" ]; then
    echo "test-release-assets: $name index_present=$actual_index; expected $expected_index" >&2
    return 1
  fi
  if [ "$actual_gallery" != "$expected_gallery" ]; then
    echo "test-release-assets: $name gallery_present=$actual_gallery; expected $expected_gallery" >&2
    return 1
  fi
  if [ "$actual_complete" != "$expected_complete" ]; then
    echo "test-release-assets: $name release_complete=$actual_complete; expected $expected_complete" >&2
    return 1
  fi
}

run_case missing false false false false
run_case index-only true true false false
run_case gallery-only true false true false
run_case complete true true true true

echo "test-release-assets: release asset checks OK"
