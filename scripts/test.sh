#!/usr/bin/env bash
# Run the test suites. Extra args pass through to `swift test`.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test "$@"
