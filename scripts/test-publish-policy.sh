#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kandelo-publish-policy-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/crates/shared/src" "$TMP_ROOT/packages/registry" "$TMP_ROOT/sdk"
abi="$(sed -nE 's/^[[:space:]]*kernel_abi[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$REPO_ROOT/packages/ruby/package.toml" | head -1)"
[ -n "$abi" ] || {
  echo "test-publish-policy: could not read ruby kernel_abi" >&2
  exit 1
}
printf 'pub const ABI_VERSION: u32 = %s;\n' "$abi" > "$TMP_ROOT/crates/shared/src/lib.rs"
printf '#!/usr/bin/env bash\n' > "$TMP_ROOT/sdk/activate.sh"
chmod +x "$TMP_ROOT/sdk/activate.sh"

output="$TMP_ROOT/output.log"
set +e
"$REPO_ROOT/scripts/build-and-publish.sh" \
  --software-root "$REPO_ROOT" \
  --kandelo-root "$TMP_ROOT" \
  --packages ruby \
  --target-tag "binaries-abi-v$abi" >"$output" 2>&1
rc=$?
set -e

if [ "$rc" -ne 1 ]; then
  cat "$output" >&2
  echo "test-publish-policy: expected explicit ruby publish to fail with status 1, got $rc" >&2
  exit 1
fi

if ! grep -q 'ruby is disabled for publishing' "$output"; then
  cat "$output" >&2
  echo "test-publish-policy: expected disabled ruby message" >&2
  exit 1
fi

echo "test-publish-policy: disabled package policy OK"
