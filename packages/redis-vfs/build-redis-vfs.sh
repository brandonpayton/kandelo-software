#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOST_TARGET="$(rustc -vV | awk '/^host/ {print $2}')"
SYSROOT="$REPO_ROOT/sysroot"

stage_libcxx() {
  if [ -f "$SYSROOT/lib/libc++.a" ] && [ -f "$SYSROOT/lib/libc++abi.a" ]; then
    return 0
  fi

  echo "==> Resolving libcxx for dinit..."
  cargo run --release -p xtask --target "$HOST_TARGET" --quiet -- \
    build-deps --arch wasm32 resolve libcxx >/dev/null
  libcxx_prefix="$(cargo run --release -p xtask --target "$HOST_TARGET" --quiet -- \
    build-deps --arch wasm32 path libcxx)"

  ln -sf "$libcxx_prefix/lib/libc++.a" "$SYSROOT/lib/libc++.a"
  ln -sf "$libcxx_prefix/lib/libc++abi.a" "$SYSROOT/lib/libc++abi.a"
  mkdir -p "$SYSROOT/include/c++"
  rm -rf "$SYSROOT/include/c++/v1"
  ln -sfn "$libcxx_prefix/include/c++/v1" "$SYSROOT/include/c++/v1"
}

cargo run --release -p xtask --target "$HOST_TARGET" --quiet -- \
  build-deps --arch wasm32 --binaries-dir "$REPO_ROOT/binaries" resolve redis
stage_libcxx
cargo run --release -p xtask --target "$HOST_TARGET" --quiet -- \
  build-deps --arch wasm32 --binaries-dir "$REPO_ROOT/binaries" resolve dinit
bash "$REPO_ROOT/images/vfs/scripts/build-redis-vfs-image.sh"
VFS="$REPO_ROOT/apps/browser-demos/public/redis.vfs.zst"
[ -f "$VFS" ] || { echo "ERROR: $VFS not produced" >&2; exit 1; }
STAGE="$SCRIPT_DIR/redis-vfs.vfs.zst"
cp "$VFS" "$STAGE"
source "$REPO_ROOT/scripts/install-local-binary.sh"
install_local_binary redis-vfs "$STAGE"
