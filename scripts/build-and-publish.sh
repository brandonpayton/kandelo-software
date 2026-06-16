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

ABI="$(grep -oE 'ABI_VERSION: u32 = [0-9]+' crates/shared/src/lib.rs | awk '{print $4}' || true)"
[ -n "$ABI" ] || {
  echo "build-and-publish: could not read Kandelo ABI_VERSION" >&2
  exit 2
}
TARGET_TAG="${TARGET_TAG:-binaries-abi-v${ABI}}"
"$SOFTWARE_ROOT/scripts/validate-abi-metadata.sh" \
  --software-root "$SOFTWARE_ROOT" \
  --kandelo-root "$KANDELO_ROOT" \
  --packages "$PACKAGE_SELECTION" \
  --target-tag "$TARGET_TAG"
PACKAGE_REGISTRY="$KANDELO_ROOT/packages/registry"
HOST_TARGET=""
BUILD_TIMESTAMP="$(git -C "$SOFTWARE_ROOT" log -1 --format=%aI HEAD 2>/dev/null || date -u +%FT%TZ)"
BUILD_COMMIT="$(git -C "$SOFTWARE_ROOT" rev-parse HEAD 2>/dev/null || echo local)"
BUILD_HOST="${REPOSITORY}@${BUILD_COMMIT}"
TARGET_RELEASE_ASSETS_JSON="[]"
TARGET_RELEASE_HAS_INDEX=false

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

selection_is_all() {
  [ "$PACKAGE_SELECTION" = "all" ] || [ -z "$PACKAGE_SELECTION" ]
}

publish_policy_field() {
  local pkg="$1"
  local field="$2"
  local file="$SOFTWARE_ROOT/packages/$pkg/publish.toml"
  local in_publish=0
  local line

  [ -f "$file" ] || return 0
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue

    if [[ "$line" =~ ^\[[^]]+\]$ ]]; then
      if [ "$line" = "[publish]" ]; then
        in_publish=1
      else
        in_publish=0
      fi
      continue
    fi

    if [ "$in_publish" -eq 1 ] && [[ "$line" =~ ^$field[[:space:]]*=[[:space:]]*\"(.*)\"[[:space:]]*$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
    if [ "$in_publish" -eq 1 ] && [[ "$line" =~ ^$field[[:space:]]*=[[:space:]]*(true|false)[[:space:]]*$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done < "$file"
}

publish_enabled() {
  local pkg="$1"
  local enabled
  enabled="$(publish_policy_field "$pkg" enabled || true)"
  [ "$enabled" != "false" ]
}

load_target_release_assets() {
  if TARGET_RELEASE_ASSETS_JSON="$(gh release view "$TARGET_TAG" --repo "$REPOSITORY" --json assets --jq '[.assets[].name]' 2>/dev/null)"; then
    if jq -e 'index("index.toml")' <<<"$TARGET_RELEASE_ASSETS_JSON" >/dev/null; then
      TARGET_RELEASE_HAS_INDEX=true
    fi
  else
    TARGET_RELEASE_ASSETS_JSON="[]"
  fi
}

target_release_asset_present() {
  local asset_name="$1"
  jq -e --arg name "$asset_name" 'index($name)' <<<"$TARGET_RELEASE_ASSETS_JSON" >/dev/null
}

target_release_archive_present() {
  local pkg="$1"
  local suffix="$2"
  jq -e --arg pre "${pkg}-" --arg suf "$suffix" 'any(.[]; startswith($pre) and endswith($suf))' <<<"$TARGET_RELEASE_ASSETS_JSON" >/dev/null
}

upload_gallery_metadata() {
  if [ ! -f "$SOFTWARE_ROOT/gallery.json" ]; then
    return 0
  fi
  if ! gh release view "$TARGET_TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    return 0
  fi

  gh release upload "$TARGET_TAG" --repo "$REPOSITORY" --clobber "$SOFTWARE_ROOT/gallery.json"
  echo "build-and-publish: uploaded $TARGET_TAG/gallery.json"
}

host_target() {
  if [ -z "$HOST_TARGET" ]; then
    HOST_TARGET="$(rustc -vV | awk '/^host/ {print $2}')"
  fi
  printf '%s\n' "$HOST_TARGET"
}

build_publish_one() {
  local pkg="$1"
  local version="$2"
  local revision="$3"
  local arch="$4"
  local pkg_dir="$PACKAGE_REGISTRY/$pkg"

  local cargo_target sha short suffix out_dir archive_path archive_name
  cargo_target="$(host_target)"
  sha="$(cargo run --release -p xtask --target "$cargo_target" --quiet -- \
    compute-cache-key-sha --package "$pkg_dir" --arch "$arch")"
  short="${sha:0:8}"
  suffix="-abi${ABI}-${arch}-${short}.tar.zst"

  if target_release_archive_present "$pkg" "$suffix" && [ "$TARGET_RELEASE_HAS_INDEX" = true ]; then
    echo "build-and-publish: skip $pkg/$arch ($short already published)"
    return 0
  fi
  if target_release_archive_present "$pkg" "$suffix" ]; then
    echo "build-and-publish: refresh $pkg/$arch ($short archive exists but index.toml is missing)"
  fi

  out_dir="${RUNNER_TEMP:-/tmp}/kandelo-software-staged/$pkg-$arch"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  echo "build-and-publish: staging $pkg $version rev$revision $arch"
  cargo run --release -p xtask --target "$cargo_target" --quiet -- \
    archive-stage \
      --package "$pkg_dir" \
      --arch "$arch" \
      --out "$out_dir" \
      --build-timestamp "$BUILD_TIMESTAMP" \
      --build-host "$BUILD_HOST"

  archive_path="$(find "$out_dir" -name '*.tar.zst' -print -quit)"
  if [ -z "$archive_path" ]; then
    echo "build-and-publish: no archive produced for $pkg/$arch" >&2
    return 1
  fi
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

load_target_release_assets
if target_release_asset_present gallery.json; then
  echo "build-and-publish: release gallery.json already published"
elif gh release view "$TARGET_TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  echo "build-and-publish: release gallery.json missing; it will be uploaded after package checks"
fi
if [ "$TARGET_RELEASE_HAS_INDEX" != true ] && gh release view "$TARGET_TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  echo "build-and-publish: release index.toml missing; published archives will be refreshed"
fi

mapfile -t ordered <"$SOFTWARE_ROOT/packages.txt"
for pkg in "${ordered[@]}"; do
  [ -n "$pkg" ] || continue
  want_pkg "$pkg" || continue

  if ! publish_enabled "$pkg"; then
    reason="$(publish_policy_field "$pkg" reason || true)"
    reason="${reason:-not publishable by policy}"
    if selection_is_all; then
      echo "build-and-publish: skip $pkg (publish disabled: $reason)"
      continue
    fi
    echo "build-and-publish: $pkg is disabled for publishing: $reason" >&2
    FAILED+=("$pkg/disabled")
    continue
  fi

  pkg_dir="$PACKAGE_REGISTRY/$pkg"
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

upload_gallery_metadata
