#!/usr/bin/env bash
set -euo pipefail

KANDELO_ROOT=""
ARCHES="wasm32"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kandelo-root) KANDELO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --arches) ARCHES="$2"; shift 2 ;;
    *) echo "stage-kandelo-libcxx: unknown flag $1" >&2; exit 2 ;;
  esac
done

if [ -z "$KANDELO_ROOT" ]; then
  echo "stage-kandelo-libcxx: --kandelo-root is required" >&2
  exit 2
fi

cd "$KANDELO_ROOT"
if [ -f "$KANDELO_ROOT/sdk/activate.sh" ]; then
  # shellcheck source=/dev/null
  source "$KANDELO_ROOT/sdk/activate.sh"
fi

HOST_TARGET="$(rustc -vV | awk '/^host/ {print $2}')"

stage_arch() {
  local arch="$1"
  local sysroot
  local libcxx_prefix

  case "$arch" in
    wasm32) sysroot="$KANDELO_ROOT/sysroot" ;;
    wasm64) sysroot="$KANDELO_ROOT/sysroot64" ;;
    *) echo "stage-kandelo-libcxx: unsupported arch: $arch" >&2; return 2 ;;
  esac

  if [ ! -f "$sysroot/lib/libc.a" ]; then
    echo "stage-kandelo-libcxx: sysroot missing for $arch: $sysroot" >&2
    return 1
  fi

  echo "stage-kandelo-libcxx: resolving libcxx for $arch"
  cargo run --release -p xtask --target "$HOST_TARGET" --quiet -- \
    build-deps --arch "$arch" resolve libcxx >/dev/null
  libcxx_prefix="$(cargo run --release -p xtask --target "$HOST_TARGET" --quiet -- \
    build-deps --arch "$arch" path libcxx)"

  for archive in "$libcxx_prefix/lib/libc++.a" "$libcxx_prefix/lib/libc++abi.a"; do
    if [ ! -f "$archive" ]; then
      echo "stage-kandelo-libcxx: resolver returned $libcxx_prefix but $(basename "$archive") is missing" >&2
      return 1
    fi
  done
  if [ ! -d "$libcxx_prefix/include/c++/v1" ]; then
    echo "stage-kandelo-libcxx: resolver returned $libcxx_prefix but libc++ headers are missing" >&2
    return 1
  fi

  mkdir -p "$sysroot/lib" "$sysroot/include/c++"
  ln -sf "$libcxx_prefix/lib/libc++.a" "$sysroot/lib/libc++.a"
  ln -sf "$libcxx_prefix/lib/libc++abi.a" "$sysroot/lib/libc++abi.a"
  rm -rf "$sysroot/include/c++/v1"
  ln -sfn "$libcxx_prefix/include/c++/v1" "$sysroot/include/c++/v1"
  echo "stage-kandelo-libcxx: staged $arch libc++ into $sysroot"
}

normalized="$(printf '%s' "$ARCHES" | tr ',' ' ')"
for arch in $normalized; do
  stage_arch "$arch"
done
