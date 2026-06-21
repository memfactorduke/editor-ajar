#!/usr/bin/env bash
# Run the report-only performance benchmark suite (SPEC §5, docs/PERFORMANCE.md).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -eq 0 ]]; then
  swift run ajar bench all
else
  swift run ajar bench "$@"
fi
