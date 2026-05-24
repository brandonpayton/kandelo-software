#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <kandelo-root>" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

SOFTWARE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KANDELO_ROOT="$(cd "$1" && pwd)"

if [ -x "$KANDELO_ROOT/scripts/sync-package-source.sh" ]; then
  exec "$KANDELO_ROOT/scripts/sync-package-source.sh" \
    --package-source-root "$SOFTWARE_ROOT" \
    --kandelo-root "$KANDELO_ROOT"
fi

echo "sync-packages: $KANDELO_ROOT does not provide scripts/sync-package-source.sh" >&2
exit 2
