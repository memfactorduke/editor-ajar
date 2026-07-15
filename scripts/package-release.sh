#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/package-release.sh --mode unsigned --version X.Y.Z [--output-dir DIR] [--build-number N]
  scripts/package-release.sh --mode production --release-tag vX.Y.Z [--output-dir DIR] [--build-number N]

Unsigned mode needs no Apple credentials and creates an explicitly non-consumer test artifact.

Production mode requires a clean checkout at the release tag and these environment variables:
  APPLE_SIGNING_IDENTITY   Developer ID Application identity already present in the keychain
  APPLE_SIGNING_KEYCHAIN   Optional path to the keychain containing that identity
  APPLE_TEAM_ID           Apple Developer team identifier
  APPLE_NOTARY_KEY_PATH   Path to an App Store Connect API private key (.p8)
  APPLE_NOTARY_KEY_ID     App Store Connect API key identifier
  APPLE_NOTARY_ISSUER_ID  App Store Connect API issuer identifier
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
mode=""
version=""
release_tag=""
output_dir="$repo_root/dist"
build_number=${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}

while (($# > 0)); do
  case "$1" in
    --mode)
      (($# >= 2)) || fail "--mode requires a value"
      mode=$2
      shift 2
      ;;
    --version)
      (($# >= 2)) || fail "--version requires a value"
      version=${2#v}
      shift 2
      ;;
    --release-tag)
      (($# >= 2)) || fail "--release-tag requires a value"
      release_tag=$2
      shift 2
      ;;
    --output-dir)
      (($# >= 2)) || fail "--output-dir requires a value"
      output_dir=$2
      shift 2
      ;;
    --build-number)
      (($# >= 2)) || fail "--build-number requires a value"
      build_number=$2
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

[[ "$mode" == "unsigned" || "$mode" == "production" ]] || fail "mode must be unsigned or production"
[[ "$build_number" =~ ^[0-9]+$ ]] && ((build_number > 0)) || fail "build number must be a positive integer"

if [[ "$mode" == "unsigned" ]]; then
  [[ -n "$version" ]] || fail "unsigned mode requires --version X.Y.Z"
  [[ -z "$release_tag" ]] || fail "unsigned mode uses --version, not --release-tag"
else
  [[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    fail "production release tag must be vX.Y.Z"
  [[ -z "$version" ]] || fail "production mode derives its version from --release-tag"
  version=${release_tag#v}

  for variable in APPLE_SIGNING_IDENTITY APPLE_TEAM_ID APPLE_NOTARY_KEY_PATH APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID; do
    value=${!variable:-}
    [[ -n "${value//[[:space:]]/}" ]] || fail "production mode requires $variable"
  done
  [[ "$APPLE_SIGNING_IDENTITY" == "Developer ID Application:"* ]] || \
    fail "APPLE_SIGNING_IDENTITY must be a Developer ID Application identity"
  [[ -r "$APPLE_NOTARY_KEY_PATH" ]] || fail "APPLE_NOTARY_KEY_PATH is not readable"
  if [[ -n "${APPLE_SIGNING_KEYCHAIN:-}" ]]; then
    [[ -f "$APPLE_SIGNING_KEYCHAIN" ]] || fail "APPLE_SIGNING_KEYCHAIN does not exist"
    security find-identity -v -p codesigning "$APPLE_SIGNING_KEYCHAIN" \
      | grep -Fq "\"${APPLE_SIGNING_IDENTITY}\"" || \
      fail "APPLE_SIGNING_IDENTITY is not valid in APPLE_SIGNING_KEYCHAIN"
  else
    security find-identity -v -p codesigning | grep -Fq "\"${APPLE_SIGNING_IDENTITY}\"" || \
      fail "APPLE_SIGNING_IDENTITY is not a valid keychain code-signing identity"
  fi

  [[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]] || \
    fail "production packaging requires a clean checkout"
  tag_ref="refs/tags/$release_tag"
  git -C "$repo_root" show-ref --verify --quiet "$tag_ref" || \
    fail "release tag does not exist locally: $release_tag"
  tag_commit=$(git -C "$repo_root" rev-parse "${tag_ref}^{commit}" 2>/dev/null) || \
    fail "release tag does not resolve to a commit: $release_tag"
  head_commit=$(git -C "$repo_root" rev-parse HEAD)
  [[ "$tag_commit" == "$head_commit" ]] || fail "HEAD does not match release tag $release_tag"
fi

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must be X.Y.Z"

for tool in xcodebuild ditto xcrun lipo codesign plutil git; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done
if [[ "$mode" == "production" ]]; then
  for tool in security spctl; do
    command -v "$tool" >/dev/null 2>&1 || fail "required production tool is unavailable: $tool"
  done
fi

mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
if [[ "$mode" == "unsigned" ]]; then
  artifact_name="EditorAjar-${version}-macOS-arm64-UNSIGNED-TEST-ONLY.zip"
else
  artifact_name="EditorAjar-${version}-macOS-arm64.zip"
fi
artifact="$output_dir/$artifact_name"
[[ ! -e "$artifact" ]] || fail "refusing to overwrite existing artifact: $artifact"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/editor-ajar-package.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
archive_path="$work_dir/EditorAjar.xcarchive"
derived_data="$work_dir/DerivedData"

build_settings=(
  "ARCHS=arm64"
  "ONLY_ACTIVE_ARCH=NO"
  "MACOSX_DEPLOYMENT_TARGET=14.0"
  "MARKETING_VERSION=$version"
  "CURRENT_PROJECT_VERSION=$build_number"
)

if [[ "$mode" == "unsigned" ]]; then
  build_settings+=(
    "CODE_SIGNING_ALLOWED=NO"
    "CODE_SIGNING_REQUIRED=NO"
    "ENABLE_HARDENED_RUNTIME=NO"
  )
else
  code_sign_flags="--timestamp"
  if [[ -n "${APPLE_SIGNING_KEYCHAIN:-}" ]]; then
    code_sign_flags+=" --keychain $APPLE_SIGNING_KEYCHAIN"
  fi
  build_settings+=(
    "CODE_SIGNING_ALLOWED=YES"
    "CODE_SIGNING_REQUIRED=YES"
    "CODE_SIGN_STYLE=Manual"
    "CODE_SIGN_IDENTITY=$APPLE_SIGNING_IDENTITY"
    "DEVELOPMENT_TEAM=$APPLE_TEAM_ID"
    "ENABLE_HARDENED_RUNTIME=YES"
    "OTHER_CODE_SIGN_FLAGS=$code_sign_flags"
  )
fi

echo "Building EditorAjar.app ($mode, version $version, build $build_number)..."
xcodebuild archive \
  -project "$repo_root/app/EditorAjar/EditorAjar.xcodeproj" \
  -scheme EditorAjar \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  -derivedDataPath "$derived_data" \
  "${build_settings[@]}"

app="$archive_path/Products/Applications/EditorAjar.app"
[[ -d "$app" ]] || fail "archive did not produce EditorAjar.app"

if [[ "$mode" == "production" ]]; then
  codesign --verify --deep --strict --verbose=2 "$app"
  signature_details=$(codesign -d --verbose=4 "$app" 2>&1)
  grep -Fq "Authority=Developer ID Application:" <<<"$signature_details" || \
    fail "Xcode did not apply a Developer ID Application signature"
  grep -Eq 'flags=.*runtime' <<<"$signature_details" || fail "Xcode did not enable hardened runtime"
  grep -Fq "TeamIdentifier=${APPLE_TEAM_ID}" <<<"$signature_details" || \
    fail "signed app team does not match APPLE_TEAM_ID"

  notary_upload="$work_dir/EditorAjar-${version}-notary.zip"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$notary_upload"
  notary_result="$work_dir/notary-result.json"
  echo "Submitting signed app to Apple notarization..."
  if ! xcrun notarytool submit "$notary_upload" \
    --key "$APPLE_NOTARY_KEY_PATH" \
    --key-id "$APPLE_NOTARY_KEY_ID" \
    --issuer "$APPLE_NOTARY_ISSUER_ID" \
    --wait \
    --timeout 30m \
    --output-format json >"$notary_result"; then
    cat "$notary_result" >&2
    fail "Apple notarization submission failed"
  fi
  notarization_status=$(plutil -extract status raw -o - "$notary_result")
  [[ "$notarization_status" == "Accepted" ]] || {
    cat "$notary_result" >&2
    fail "Apple notarization status is $notarization_status, not Accepted"
  }

  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$work_dir/$artifact_name"
else
  stage="$work_dir/stage"
  mkdir -p "$stage"
  ditto "$app" "$stage/EditorAjar.app"
  printf '%s\n' \
    'UNSIGNED TEST ARTIFACT — NOT A CONSUMER RELEASE' \
    'This package has no Developer ID/notarization assurance and Gatekeeper may reject it.' \
    'Build a production artifact through docs/RELEASING.md before distributing to users.' \
    >"$stage/UNSIGNED-TEST-ONLY.txt"
  ditto -c -k --sequesterRsrc "$stage" "$work_dir/$artifact_name"
fi

APPLE_TEAM_ID=${APPLE_TEAM_ID:-} "$script_dir/verify-release-artifact.sh" \
  --artifact "$work_dir/$artifact_name" \
  --version "$version" \
  --mode "$mode"

mv "$work_dir/$artifact_name" "$artifact"
echo "ARTIFACT: $artifact"
