#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

SQUEAK_VM_FLAVOR=v3 \
SQUEAK_PACKAGE_NAME=squeak-v3 \
SQUEAK_OUTPUT_NAME=squeak-v3.wasm \
    bash "$REPO_ROOT/packages/registry/squeak/build-squeak.sh"
