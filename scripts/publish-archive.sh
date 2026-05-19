#!/usr/bin/env bash
set -euo pipefail

TARGET_TAG=""
PACKAGE=""
VERSION=""
REVISION=""
ARCH=""
ARCHIVE_PATH=""
ARCHIVE_NAME=""
CACHE_KEY_SHA=""
KANDELO_ROOT=""
REPOSITORY="${GITHUB_REPOSITORY:-brandonpayton/kandelo-software}"
SOFTWARE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target-tag) TARGET_TAG="$2"; shift 2 ;;
    --package) PACKAGE="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --revision) REVISION="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --archive-path) ARCHIVE_PATH="$2"; shift 2 ;;
    --archive-name) ARCHIVE_NAME="$2"; shift 2 ;;
    --cache-key-sha) CACHE_KEY_SHA="$2"; shift 2 ;;
    --kandelo-root) KANDELO_ROOT="$2"; shift 2 ;;
    --repo) REPOSITORY="$2"; shift 2 ;;
    *) echo "publish-archive: unknown flag $1" >&2; exit 2 ;;
  esac
done

require() {
  local name="$1" value="$2"
  if [ -z "$value" ]; then
    echo "publish-archive: --$name is required" >&2
    exit 2
  fi
}

require target-tag "$TARGET_TAG"
require package "$PACKAGE"
require version "$VERSION"
require revision "$REVISION"
require arch "$ARCH"
require archive-path "$ARCHIVE_PATH"
require archive-name "$ARCHIVE_NAME"
require cache-key-sha "$CACHE_KEY_SHA"
require kandelo-root "$KANDELO_ROOT"

[ -f "$ARCHIVE_PATH" ] || {
  echo "publish-archive: archive not found: $ARCHIVE_PATH" >&2
  exit 2
}

cd "$KANDELO_ROOT"

INDEX_DIR="$(mktemp -d)"
INDEX_PATH="$INDEX_DIR/index.toml"

if gh release view "$TARGET_TAG" --repo "$REPOSITORY" --json assets --jq '.assets[].name' 2>/dev/null | grep -qx 'index.toml'; then
  gh release download "$TARGET_TAG" --repo "$REPOSITORY" --pattern index.toml --dir "$INDEX_DIR" --clobber
else
  ABI="${TARGET_TAG#binaries-abi-v}"
  cat >"$INDEX_PATH" <<EOF
abi_version = $ABI
generated_at = "$(date -u +%FT%TZ)"
generator = "kandelo-software publish-archive.sh bootstrap"
EOF
fi

HOST_TARGET="$(rustc -vV | awk '/^host/ {print $2}')"
cargo run --release -p xtask --target "$HOST_TARGET" --quiet -- \
  index-update \
    --index-path "$INDEX_PATH" \
    --package "$PACKAGE" \
    --version "$VERSION" \
    --revision "$REVISION" \
    --arch "$ARCH" \
    --status success \
    --archive-path "$ARCHIVE_PATH" \
    --archive-name "$ARCHIVE_NAME" \
    --cache-key-sha "$CACHE_KEY_SHA" \
    --built-at "$(date -u +%FT%TZ)" \
    --built-by "${GITHUB_SERVER_URL:-https://github.com}/${REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-local}"

if ! gh release view "$TARGET_TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  release_args=(
    "$TARGET_TAG"
    --repo "$REPOSITORY" \
    --title "$TARGET_TAG" \
    --notes "Kandelo software packages for ABI ${TARGET_TAG#binaries-abi-v}"
  )
  if [ -n "${GITHUB_SHA:-}" ]; then
    release_args+=(--target "$GITHUB_SHA")
  fi
  gh release create "${release_args[@]}"
fi

gh release upload "$TARGET_TAG" --repo "$REPOSITORY" --clobber "$ARCHIVE_PATH"
gh release upload "$TARGET_TAG" --repo "$REPOSITORY" --clobber "$INDEX_PATH"

if [ -f "$SOFTWARE_ROOT/gallery.json" ]; then
  gh release upload "$TARGET_TAG" --repo "$REPOSITORY" --clobber "$SOFTWARE_ROOT/gallery.json"
fi

echo "publish-archive: published $ARCHIVE_NAME and updated $TARGET_TAG/index.toml"
