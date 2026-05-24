#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/sdk/activate.sh"

HOST_TARGET="$(rustc -vV | awk '/^host/ {print $2}')"

resolve_dep() {
  local name="$1"
  cargo run --release -p xtask --target "$HOST_TARGET" --quiet -- \
    build-deps --arch wasm32 --binaries-dir "$REPO_ROOT/binaries" resolve "$name"
}

SDK_DIR="${WASM_POSIX_DEP_KANDELO_SDK_DIR:-}"
CLANG_DIR="${WASM_POSIX_DEP_CLANG_DIR:-}"

if [[ -z "$SDK_DIR" || ! -f "$SDK_DIR/kandelo-sdk.vfs.zst" ]]; then
  SDK_DIR="$(resolve_dep kandelo-sdk)"
fi

if [[ -z "$CLANG_DIR" || ! -f "$CLANG_DIR/clang.wasm" || ! -f "$CLANG_DIR/wasm-ld.wasm" ]]; then
  CLANG_DIR="$(resolve_dep clang)"
fi

export KANDELO_SDK_VFS_IN="$SDK_DIR/kandelo-sdk.vfs.zst"
export KANDELO_CLANG_BIN_DIR="$CLANG_DIR"
export KANDELO_CLANG_DEMO_VFS_OUT="$SCRIPT_DIR/clang-demo-vfs.vfs.zst"

(
  cd "$REPO_ROOT"
  npx tsx "$SCRIPT_DIR/build-clang-demo-vfs-image.ts"
)

VFS="$SCRIPT_DIR/clang-demo-vfs.vfs.zst"
[[ -f "$VFS" ]] || { echo "ERROR: $VFS not produced by builder" >&2; exit 1; }

source "$REPO_ROOT/scripts/install-local-binary.sh"
install_local_binary clang-demo-vfs "$VFS"
