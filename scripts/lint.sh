#!/usr/bin/env bash
# Lint + format-check, mirroring the CI 'lint' job (.github/workflows/ci.yml).
set -euo pipefail
cd "$(dirname "$0")/.."

# App identity assets (#265): master + AppIcon.appiconset integrity (offline).
bash scripts/verify-app-icon.sh

if command -v swiftlint >/dev/null 2>&1; then
  swiftlint --strict
else
  echo "swiftlint not installed — 'brew install swiftlint'"; exit 1
fi

if command -v swift-format >/dev/null 2>&1; then
  swift-format lint --recursive Sources Tests
else
  echo "swift-format not installed — skipping format check ('brew install swift-format')."
fi
