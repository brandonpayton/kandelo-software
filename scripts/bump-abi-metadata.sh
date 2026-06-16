#!/usr/bin/env bash
set -euo pipefail

SOFTWARE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ABI=""
KANDELO_ROOT=""
KANDELO_REPOSITORY=""
KANDELO_REF=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --software-root) SOFTWARE_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --abi) ABI="$2"; shift 2 ;;
    --kandelo-root) KANDELO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --kandelo-repository) KANDELO_REPOSITORY="$2"; shift 2 ;;
    --kandelo-ref) KANDELO_REF="$2"; shift 2 ;;
    *) echo "bump-abi-metadata: unknown flag $1" >&2; exit 2 ;;
  esac
done

read_json_field() {
  local file="$1"
  local field="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg field "$field" '.[$field] // empty' "$file"
  else
    sed -nE 's/^[[:space:]]*"'"$field"'"[[:space:]]*:[[:space:]]*"?([^",}]*)"?[,]?[[:space:]]*$/\1/p' "$file" | head -1
  fi
}

if [ -n "$KANDELO_ROOT" ]; then
  ABI_FROM_KANDELO="$(grep -oE 'ABI_VERSION: u32 = [0-9]+' "$KANDELO_ROOT/crates/shared/src/lib.rs" | awk '{print $4}' || true)"
  [ -n "$ABI_FROM_KANDELO" ] || {
    echo "bump-abi-metadata: could not read Kandelo ABI_VERSION" >&2
    exit 2
  }
  if [ -n "$ABI" ] && [ "$ABI" != "$ABI_FROM_KANDELO" ]; then
    echo "bump-abi-metadata: --abi $ABI does not match Kandelo ABI $ABI_FROM_KANDELO" >&2
    exit 2
  fi
  ABI="$ABI_FROM_KANDELO"
  if [ -z "$KANDELO_REF" ]; then
    KANDELO_REF="$(git -C "$KANDELO_ROOT" rev-parse HEAD 2>/dev/null || true)"
  fi
fi

if [ -z "$ABI" ] || ! [[ "$ABI" =~ ^[0-9]+$ ]]; then
  echo "bump-abi-metadata: --abi <N> or --kandelo-root <dir> is required" >&2
  exit 2
fi

METADATA_FILE="$SOFTWARE_ROOT/kandelo-abi.json"
if [ -f "$METADATA_FILE" ]; then
  KANDELO_REPOSITORY="${KANDELO_REPOSITORY:-$(read_json_field "$METADATA_FILE" kandelo_repository)}"
  KANDELO_REF="${KANDELO_REF:-$(read_json_field "$METADATA_FILE" kandelo_ref)}"
fi
KANDELO_REPOSITORY="${KANDELO_REPOSITORY:-brandonpayton/wasm-posix-kernel}"
KANDELO_REF="${KANDELO_REF:-main}"

shopt -s nullglob
package_files=("$SOFTWARE_ROOT"/packages/*/package.toml)
if [ "${#package_files[@]}" -eq 0 ]; then
  echo "bump-abi-metadata: no package.toml files found under $SOFTWARE_ROOT/packages" >&2
  exit 2
fi

for package_file in "${package_files[@]}"; do
  if ! grep -Eq '^[[:space:]]*kernel_abi[[:space:]]*=' "$package_file"; then
    echo "bump-abi-metadata: missing kernel_abi in $package_file" >&2
    exit 1
  fi
  perl -0pi -e 's/^[[:space:]]*kernel_abi[[:space:]]*=[[:space:]]*[0-9]+/kernel_abi = '"$ABI"'/m' "$package_file"
done

if [ -f "$SOFTWARE_ROOT/gallery.json" ]; then
  perl -0pi -e 's/"release_tag"[[:space:]]*:[[:space:]]*"binaries-abi-v[0-9]+"/"release_tag": "binaries-abi-v'"$ABI"'"/' "$SOFTWARE_ROOT/gallery.json"
fi

if [ -f "$SOFTWARE_ROOT/docs/maintaining.md" ]; then
  perl -0pi -e 's/set targets ABI [0-9]+/set targets ABI '"$ABI"'/g' "$SOFTWARE_ROOT/docs/maintaining.md"
fi

cat >"$METADATA_FILE" <<EOF
{
  "schema": 1,
  "abi": $ABI,
  "release_tag": "binaries-abi-v$ABI",
  "kandelo_repository": "$KANDELO_REPOSITORY",
  "kandelo_ref": "$KANDELO_REF"
}
EOF

echo "bump-abi-metadata: updated package metadata for Kandelo ABI $ABI from $KANDELO_REPOSITORY@$KANDELO_REF"
