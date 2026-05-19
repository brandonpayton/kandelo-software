#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
bash "$REPO_ROOT/examples/browser/scripts/build-redis-vfs-image.sh"
VFS="$REPO_ROOT/examples/browser/public/redis.vfs.zst"
[ -f "$VFS" ] || { echo "ERROR: $VFS not produced" >&2; exit 1; }
STAGE="$SCRIPT_DIR/redis-vfs.vfs.zst"
cp "$VFS" "$STAGE"
source "$REPO_ROOT/scripts/install-local-binary.sh"
install_local_binary redis-vfs "$STAGE"
