#!/usr/bin/env bash
# check-hardcoded-strings.sh — localization-readiness lint for the EditorAjar app target
# (NFR-I18N-001). REPORT-ONLY: this script never fails the build. It greps the app sources for
# user-visible string literals that do NOT flow through the `AppString` catalog accessor, so a
# reviewer can spot newly-added hardcoded copy.
#
# It is deliberately simple and WILL emit false positives — data interpolations, format helpers,
# and a few intentional acronyms (PNG/JPEG/WAV/M4A) are not localized. Accessibility *identifiers*
# are intentionally literal and are excluded. Treat the output as a checklist, not a gate.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/app/EditorAjar/Sources"

if [ ! -d "${SRC}" ]; then
  echo "check-hardcoded-strings: app sources not found at ${SRC}; nothing to check."
  exit 0
fi

# User-visible string APIs whose literal argument should normally be an AppString catalog lookup.
# accessibilityIdentifier is intentionally excluded (identifiers stay stable, non-localized).
PATTERN='(\bText\("|\bButton\("|\bToggle\("|\bLabel\("|\bMenu\("|\bCommandMenu\("|\bPicker\("|\.help\("|\.accessibilityLabel\("|\.accessibilityHint\("|\.accessibilityValue\(")'

report="$(
  grep -rEn "${PATTERN}" "${SRC}"/*.swift 2>/dev/null \
    | grep -v 'AppString' \
    | grep -v 'accessibilityIdentifier' \
    `# ignore pure data interpolations like Text("\(model.value)") / accessibilityValue("\(a), \(b)")` \
    | grep -vE '\("\\\(' \
    || true
)"

echo "== Hardcoded user-string report (NFR-I18N-001, report-only) =="
if [ -z "${report}" ]; then
  echo "No un-externalized user-visible string literals found in the app target."
  echo "(Reminder: intentional acronyms and pure data interpolations are expected to be absent here.)"
  exit 0
fi

count="$(printf '%s\n' "${report}" | grep -c . || true)"
echo "Found ${count} line(s) that may contain un-externalized user-visible copy:"
echo
printf '%s\n' "${report}"
echo
echo "If any of the above is user-visible text, route it through AppString.localized(\"<key>\", \"<English>\")."
echo "This check is report-only and does not fail CI."
exit 0
