#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

cd "$REPO_ROOT"
npx tsx "$SCRIPT_DIR/build-squeak-etoys-vfs.ts"

VFS="$REPO_ROOT/apps/browser-demos/public/squeak-etoys-vfs.vfs.zst"
[ -f "$VFS" ] || { echo "ERROR: $VFS not produced" >&2; exit 1; }

source "$REPO_ROOT/scripts/install-local-binary.sh"
install_local_binary squeak-etoys-vfs "$VFS"
