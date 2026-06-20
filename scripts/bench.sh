#!/usr/bin/env bash
# Run the performance benchmark suite against the baseline (SPEC §5, docs/PERFORMANCE.md).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Benchmarks are wired at ROADMAP M2, once the render pipeline + 'ajar bench' harness exist."
echo "They will run on the reference machine and fail on regression beyond the noise band (ADR-0011)."
exit 0
