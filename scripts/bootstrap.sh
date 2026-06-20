#!/usr/bin/env bash
# Verify the local toolchain for Editor Ajar development. Safe to run repeatedly.
set -euo pipefail

echo "Editor Ajar — environment check"
echo "================================"

os="$(uname -s)"
[ "$os" = "Darwin" ] || echo "WARNING: Editor Ajar targets macOS (ADR-0002); found '$os'."

if command -v swift >/dev/null 2>&1; then
  echo "swift:       $(swift --version 2>/dev/null | head -n1)"
else
  echo "swift:       MISSING — install Xcode or the Swift toolchain."
fi

if command -v xcodebuild >/dev/null 2>&1; then
  echo "xcode:       $(xcodebuild -version 2>/dev/null | head -n1)"
else
  echo "xcode:       not found (needed for the app target at M2)."
fi

command -v swiftlint    >/dev/null 2>&1 && echo "swiftlint:   $(swiftlint version)"        || echo "swiftlint:   MISSING — 'brew install swiftlint'"
command -v swift-format >/dev/null 2>&1 && echo "swift-format: present"                     || echo "swift-format: MISSING — 'brew install swift-format'"

echo
echo "Next: 'swift build' then 'swift test'. See CLAUDE.md and docs/ROADMAP.md."
