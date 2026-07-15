#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat <<'EOF'
Usage: scripts/verify-release-artifact.sh --artifact PATH --version X.Y.Z --mode unsigned|production

Verifies the packaged Editor Ajar application without modifying it. Production verification also
requires a Developer ID signature, hardened runtime, a stapled notarization ticket, and a passing
Gatekeeper assessment. Set APPLE_TEAM_ID to additionally require an exact signing team.
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

artifact=""
version=""
mode=""

while (($# > 0)); do
  case "$1" in
    --artifact)
      (($# >= 2)) || fail "--artifact requires a value"
      artifact=$2
      shift 2
      ;;
    --version)
      (($# >= 2)) || fail "--version requires a value"
      version=${2#v}
      shift 2
      ;;
    --mode)
      (($# >= 2)) || fail "--mode requires a value"
      mode=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -f "$artifact" ]] || fail "artifact does not exist: $artifact"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must be X.Y.Z"
[[ "$mode" == "unsigned" || "$mode" == "production" ]] || fail "mode must be unsigned or production"

for tool in ditto lipo xcrun codesign /usr/libexec/PlistBuddy; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done
if [[ "$mode" == "production" ]]; then
  command -v spctl >/dev/null 2>&1 || fail "required production tool is unavailable: spctl"
fi

artifact_name=$(basename "$artifact")
if [[ "$mode" == "unsigned" ]]; then
  [[ "$artifact_name" == *-UNSIGNED-TEST-ONLY.zip ]] || \
    fail "unsigned artifact name must end in -UNSIGNED-TEST-ONLY.zip"
else
  [[ "$artifact_name" != *UNSIGNED* ]] || fail "production artifact must not carry an unsigned label"
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/editor-ajar-release-verify.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
ditto -x -k "$artifact" "$work_dir/extracted"

app="$work_dir/extracted/EditorAjar.app"
plist="$app/Contents/Info.plist"
executable="$app/Contents/MacOS/EditorAjar"
[[ -d "$app" ]] || fail "archive must contain EditorAjar.app at its root"
[[ -f "$plist" ]] || fail "app is missing Contents/Info.plist"
[[ -x "$executable" ]] || fail "app is missing its executable"

top_level_count=0
while IFS= read -r entry; do
  name=$(basename "$entry")
  [[ "$name" == "__MACOSX" ]] && continue
  case "$mode:$name" in
    unsigned:EditorAjar.app|unsigned:UNSIGNED-TEST-ONLY.txt|production:EditorAjar.app)
      ;;
    *)
      fail "unexpected top-level package content: $name"
      ;;
  esac
  ((top_level_count += 1))
done < <(find "$work_dir/extracted" -mindepth 1 -maxdepth 1 -print)
if [[ "$mode" == "unsigned" ]]; then
  [[ "$top_level_count" -eq 2 ]] || fail "unsigned package must contain only the app and warning marker"
else
  [[ "$top_level_count" -eq 1 ]] || fail "production package must contain only EditorAjar.app"
fi

read_plist() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$plist"
}

bundle_id=$(read_plist CFBundleIdentifier)
bundle_version=$(read_plist CFBundleShortVersionString)
build_number=$(read_plist CFBundleVersion)
minimum_macos=$(read_plist LSMinimumSystemVersion)

[[ "$bundle_id" == "org.editorajar.EditorAjar" ]] || fail "unexpected bundle identifier: $bundle_id"
[[ "$bundle_version" == "$version" ]] || \
  fail "bundle version $bundle_version does not match requested version $version"
[[ "$build_number" =~ ^[0-9]+$ ]] || fail "CFBundleVersion must be a positive integer"
((build_number > 0)) || fail "CFBundleVersion must be greater than zero"
[[ "$minimum_macos" == "14.0" ]] || fail "minimum macOS must match SPEC (14.0), found $minimum_macos"

architectures=$(lipo -archs "$executable")
[[ " $architectures " == *" arm64 "* ]] || fail "application does not contain required arm64 support"

build_info=$(xcrun vtool -show-build "$executable")
grep -Eq 'minos[[:space:]]+14\.0([[:space:]]|$)' <<<"$build_info" || \
  fail "Mach-O deployment target is not macOS 14.0"

if [[ "$mode" == "unsigned" ]]; then
  marker="$work_dir/extracted/UNSIGNED-TEST-ONLY.txt"
  [[ -f "$marker" ]] || fail "unsigned package is missing UNSIGNED-TEST-ONLY.txt"
  grep -Fq "NOT A CONSUMER RELEASE" "$marker" || fail "unsigned warning marker is invalid"

  if ! signature_details=$(codesign -d --verbose=4 "$app" 2>&1); then
    grep -Fq "code object is not signed at all" <<<"$signature_details" || {
      printf '%s\n' "$signature_details" >&2
      fail "could not reliably inspect the unsigned app signature"
    }
  fi
  if grep -Fq "Authority=Developer ID Application:" <<<"$signature_details"; then
    fail "unsigned package unexpectedly contains a Developer ID application signature"
  fi
  echo "OK: unsigned/test-only label present; no Developer ID signature accepted."
else
  [[ ! -e "$work_dir/extracted/UNSIGNED-TEST-ONLY.txt" ]] || \
    fail "production package contains the unsigned warning marker"

  codesign --verify --deep --strict --verbose=2 "$app"
  signature_details=$(codesign -d --verbose=4 "$app" 2>&1)
  grep -Fq "Authority=Developer ID Application:" <<<"$signature_details" || \
    fail "production app is not signed with Developer ID Application"
  grep -Eq 'flags=.*runtime' <<<"$signature_details" || fail "hardened runtime is not enabled"
  if [[ -n "${APPLE_TEAM_ID:-}" ]]; then
    grep -Fq "TeamIdentifier=${APPLE_TEAM_ID}" <<<"$signature_details" || \
      fail "signature team does not match APPLE_TEAM_ID"
  fi

  xcrun stapler validate "$app"
  gatekeeper_output="$work_dir/gatekeeper.txt"
  if ! spctl --assess --type execute --verbose=4 "$app" >"$gatekeeper_output" 2>&1; then
    cat "$gatekeeper_output" >&2
    fail "Gatekeeper rejected the production application"
  fi
  cat "$gatekeeper_output"
  echo "OK: Developer ID signature, hardened runtime, stapling, and Gatekeeper accepted."
fi

# App identity (#265): compiled AppIcon must be present in the packaged app
# (Info.plist name, decodable AppIcon.icns, Assets.car with all macOS renditions).
# Checks the compiled artifact only — never the source tree.
"$script_dir/verify-compiled-app-icon.sh" --app "$app"

echo "OK: bundle version $bundle_version (build $build_number) matches release version $version."
echo "OK: minimum macOS $minimum_macos and architectures [$architectures] match SPEC."
echo "VERIFIED: $artifact_name ($mode)"
