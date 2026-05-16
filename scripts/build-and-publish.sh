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

"$SOFTWARE_ROOT/scripts/sync-packages.sh" "$KANDELO_ROOT"

cd "$KANDELO_ROOT"
source "$KANDELO_ROOT/sdk/activate.sh"

ABI="$(grep -oE 'ABI_VERSION: u32 = [0-9]+' crates/shared/src/lib.rs | awk '{print $4}')"
TARGET_TAG="${TARGET_TAG:-binaries-abi-v${ABI}}"
HOST_TARGET="$(rustc -vV | awk '/^host/ {print $2}')"
BUILD_TIMESTAMP="$(git -C "$SOFTWARE_ROOT" log -1 --format=%aI HEAD 2>/dev/null || date -u +%FT%TZ)"
BUILD_COMMIT="$(git -C "$SOFTWARE_ROOT" rev-parse HEAD 2>/dev/null || echo local)"
BUILD_HOST="${REPOSITORY}@${BUILD_COMMIT}"

echo "build-and-publish: Kandelo ABI $ABI"
echo "build-and-publish: target release $REPOSITORY/$TARGET_TAG"

FAILED=()

want_pkg() {
  local pkg="$1"
  if [ "$PACKAGE_SELECTION" = "all" ] || [ -z "$PACKAGE_SELECTION" ]; then
    return 0
  fi
  local normalized
  normalized="$(printf '%s' "$PACKAGE_SELECTION" | tr ',' ' ')"
  [[ " $normalized " == *" $pkg "* ]]
}

build_publish_one() {
  local pkg="$1"
  local version="$2"
  local revision="$3"
  local arch="$4"
  local pkg_dir="$KANDELO_ROOT/examples/libs/$pkg"

  local sha short suffix out_dir archive_path archive_name
  sha="$(cargo run --release -p xtask --target "$HOST_TARGET" --quiet -- \
    compute-cache-key-sha --package "$pkg_dir" --arch "$arch")"
  short="${sha:0:8}"
  suffix="-abi${ABI}-${arch}-${short}.tar.zst"

  if gh release view "$TARGET_TAG" --repo "$REPOSITORY" --json assets --jq '[.assets[].name]' 2>/dev/null \
      | jq -e --arg pre "${pkg}-" --arg suf "$suffix" 'any(.[]; startswith($pre) and endswith($suf))' >/dev/null; then
    echo "build-and-publish: skip $pkg/$arch ($short already published)"
    return 0
  fi

  out_dir="${RUNNER_TEMP:-/tmp}/kandelo-software-staged/$pkg-$arch"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  echo "build-and-publish: staging $pkg $version rev$revision $arch"
  cargo run --release -p xtask --target "$HOST_TARGET" --quiet -- \
    archive-stage \
      --package "$pkg_dir" \
      --arch "$arch" \
      --out "$out_dir" \
      --build-timestamp "$BUILD_TIMESTAMP" \
      --build-host "$BUILD_HOST"

  archive_path="$(find "$out_dir" -name '*.tar.zst' -print -quit)"
  archive_name="$(basename "$archive_path")"

  "$SOFTWARE_ROOT/scripts/publish-archive.sh" \
    --kandelo-root "$KANDELO_ROOT" \
    --repo "$REPOSITORY" \
    --target-tag "$TARGET_TAG" \
    --package "$pkg" \
    --version "$version" \
    --revision "$revision" \
    --arch "$arch" \
    --archive-path "$archive_path" \
    --archive-name "$archive_name" \
    --cache-key-sha "$sha"
}

mapfile -t ordered <"$SOFTWARE_ROOT/packages.txt"
for pkg in "${ordered[@]}"; do
  [ -n "$pkg" ] || continue
  want_pkg "$pkg" || continue

  pkg_dir="$KANDELO_ROOT/examples/libs/$pkg"
  [ -d "$pkg_dir" ] || {
    echo "build-and-publish: package missing after sync: $pkg" >&2
    exit 1
  }

  version="$(sed -nE 's/^version *= *"([^"]+)".*/\1/p' "$pkg_dir/package.toml" | head -1)"
  revision="$(sed -nE 's/^revision *= *([0-9]+).*/\1/p' "$pkg_dir/build.toml" | head -1)"
  revision="${revision:-1}"
  arches="$(awk -F'[][]' '/^arches *=/ {print $2}' "$pkg_dir/package.toml" | tr -d ' "' | tr ',' ' ')"
  arches="${arches:-wasm32}"

  for arch in $arches; do
    if ! build_publish_one "$pkg" "$version" "$revision" "$arch"; then
      echo "build-and-publish: WARN $pkg/$arch failed; continuing" >&2
      FAILED+=("$pkg/$arch")
    fi
  done
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "build-and-publish: ${#FAILED[@]} package build(s) failed:" >&2
  printf '  %s\n' "${FAILED[@]}" >&2
  exit 1
fi
