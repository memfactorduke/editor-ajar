#!/usr/bin/env bash
# verify-app-icon.sh — fail-closed offline integrity check for the Editor Ajar macOS AppIcon.
#
# Validates the approved 1024×1024 master and every AppIcon.appiconset rendition:
# expected filenames, pixel dimensions, non-empty files, valid PNGs, Contents.json
# size/scale/filename mappings, no extra files, and full-file SHA-256 hashes against
# the committed manifest app/EditorAjar/Brand/AppIcon.sha256.
#
# Hash integrity is the primary guard against same-sized unrelated/corrupted PNGs.
# Structural checks give actionable errors; hashes fail on any byte drift.
#
# Prerequisites (macOS): sips, python3, file, shasum.
# Compatible with macOS system Bash 3.2 (no associative arrays).
#
# Usage (from repo root):
#   scripts/verify-app-icon.sh                 # verify (CI / lint path)
#   scripts/verify-app-icon.sh --write-hashes  # intentional manifest refresh after regen
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="${ROOT}/app/EditorAjar/Brand/AppIcon-1024.png"
ASSETS="${ROOT}/app/EditorAjar/Resources/Assets.xcassets"
ICONSET="${ASSETS}/AppIcon.appiconset"
CONTENTS="${ICONSET}/Contents.json"
ASSETS_CONTENTS="${ASSETS}/Contents.json"
MANIFEST="${ROOT}/app/EditorAjar/Brand/AppIcon.sha256"
WRITE_HASHES=0

AT=$'@'
retina() { printf 'icon_%s%s2x.png' "$1" "$AT"; }

# point:scale:pixels
SLOTS="
16:1:16
16:2:32
32:1:32
32:2:64
128:1:128
128:2:256
256:1:256
256:2:512
512:1:512
512:2:1024
"

slot_filename() {
  local point=$1 scale=$2
  if [[ "$scale" == "1" ]]; then
    printf 'icon_%sx%s.png' "$point" "$point"
  else
    retina "${point}x${point}"
  fi
}

expected_rel_paths() {
  echo "app/EditorAjar/Brand/AppIcon-1024.png"
  echo "app/EditorAjar/Resources/Assets.xcassets/Contents.json"
  echo "app/EditorAjar/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"
  local slot point scale px name
  for slot in $SLOTS; do
    IFS=':' read -r point scale px <<<"$slot"
    name=$(slot_filename "$point" "$scale")
    echo "app/EditorAjar/Resources/Assets.xcassets/AppIcon.appiconset/${name}"
  done
}

usage() {
  cat <<'EOF'
Usage: scripts/verify-app-icon.sh [--write-hashes]

Fail-closed offline check for Brand/AppIcon-1024.png + AppIcon.appiconset.
Uses stock macOS shasum -a 256 against Brand/AppIcon.sha256.

  --write-hashes  After structural checks pass, rewrite the SHA-256 manifest
                  (intentional refresh only — never used by CI).
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
elif [[ "${1:-}" == "--write-hashes" ]]; then
  WRITE_HASHES=1
  shift
elif [[ $# -gt 0 ]]; then
  echo "ERROR: unknown argument: $1" >&2
  usage >&2
  exit 2
fi
[[ $# -eq 0 ]] || { echo "ERROR: unexpected arguments: $*" >&2; exit 2; }

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

command -v sips >/dev/null 2>&1 || fail "sips is required (macOS image tool)"
command -v python3 >/dev/null 2>&1 || fail "python3 is required (Contents.json checks)"
command -v file >/dev/null 2>&1 || fail "file is required"
command -v shasum >/dev/null 2>&1 || fail "shasum is required (SHA-256 manifest)"

[[ -f "$MASTER" ]] || fail "master icon missing: ${MASTER#"$ROOT/"}"
[[ -d "$ICONSET" ]] || fail "AppIcon.appiconset missing: ${ICONSET#"$ROOT/"}"
[[ -f "$CONTENTS" ]] || fail "Contents.json missing: ${CONTENTS#"$ROOT/"}"
[[ -f "$ASSETS_CONTENTS" ]] || fail "Assets.xcassets/Contents.json missing"

pixel_size() {
  local path=$1
  local w h
  w=$(sips -g pixelWidth "$path" 2>/dev/null | awk '/pixelWidth/ {print $2}')
  h=$(sips -g pixelHeight "$path" 2>/dev/null | awk '/pixelHeight/ {print $2}')
  [[ -n "$w" && -n "$h" ]] || fail "could not read pixel size: $path"
  printf '%s %s' "$w" "$h"
}

assert_png() {
  local path=$1 expected=$2 label=$3
  local file_out w h
  [[ -f "$path" ]] || fail "${label}: missing file ${path#"$ROOT/"}"
  [[ -s "$path" ]] || fail "${label}: empty file ${path#"$ROOT/"}"
  file_out=$(file -b "$path" || true)
  case "$file_out" in
    PNG*) ;;
    *) fail "${label}: not a PNG (${file_out}): ${path#"$ROOT/"}" ;;
  esac
  # shellcheck disable=SC2046
  set -- $(pixel_size "$path")
  w=$1
  h=$2
  [[ "$w" == "$expected" && "$h" == "$expected" ]] || \
    fail "${label}: expected ${expected}x${expected}, got ${w}x${h}: ${path#"$ROOT/"}"
}

is_expected_png_name() {
  local candidate=$1 slot point scale px name
  for slot in $SLOTS; do
    IFS=':' read -r point scale px <<<"$slot"
    name=$(slot_filename "$point" "$scale")
    if [[ "$name" == "$candidate" ]]; then
      return 0
    fi
  done
  return 1
}

write_hash_manifest() {
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/editor-ajar-appicon-sha.XXXXXX")
  (
    cd "$ROOT"
    # shellcheck disable=SC2046
    shasum -a 256 $(expected_rel_paths)
  ) | sort -k2 >"$tmp"
  mv -f "$tmp" "$MANIFEST"
  echo "OK: wrote SHA-256 manifest ${MANIFEST#"$ROOT/"} ($(wc -l <"$MANIFEST" | tr -d ' ') entries)"
}

echo "== App icon master =="
assert_png "$MASTER" 1024 "master"
master_alpha=$(sips -g hasAlpha "$MASTER" 2>/dev/null | awk '/hasAlpha/ {print $2}')
[[ "$master_alpha" == "no" ]] || fail "master must be opaque (hasAlpha=no); got hasAlpha=${master_alpha}"
echo "OK: Brand/AppIcon-1024.png is 1024x1024 opaque PNG"

echo "== AppIcon.appiconset renditions =="
expected_largest=""
expected_png_count=0
for slot in $SLOTS; do
  IFS=':' read -r point scale px <<<"$slot"
  name=$(slot_filename "$point" "$scale")
  assert_png "${ICONSET}/${name}" "$px" "$name"
  echo "OK: ${name} (${px}x${px})"
  expected_png_count=$((expected_png_count + 1))
  if [[ "$px" == "1024" ]]; then
    expected_largest="$name"
  fi
done

# Iconset inventory: allow only Contents.json + the ten required regular PNG files.
# Reject any other file, symlink, directory, or non-regular entry (fail-closed).
actual_png_count=0
contents_seen=0
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  base=$(basename "$entry")
  if [[ -L "$entry" ]]; then
    fail "unexpected symlink in iconset: $base"
  fi
  if [[ -d "$entry" ]]; then
    fail "unexpected directory in iconset: $base"
  fi
  if [[ ! -f "$entry" ]]; then
    fail "unexpected non-regular entry in iconset: $base"
  fi
  if [[ "$base" == "Contents.json" ]]; then
    contents_seen=1
    continue
  fi
  if is_expected_png_name "$base"; then
    actual_png_count=$((actual_png_count + 1))
    continue
  fi
  fail "unexpected file in iconset: $base"
done <<EOF
$(find "$ICONSET" -mindepth 1 -maxdepth 1 -print | sort)
EOF
[[ "$contents_seen" -eq 1 ]] || fail "iconset missing required Contents.json"
[[ "$actual_png_count" -eq "$expected_png_count" ]] || \
  fail "iconset PNG count ${actual_png_count} != expected ${expected_png_count}"
echo "OK: iconset contains only Contents.json + ${expected_png_count} required PNG files"

echo "== Contents.json mapping =="
python3 - "$CONTENTS" <<'PYJSON'
import json, sys
from pathlib import Path

contents_path = Path(sys.argv[1])
data = json.loads(contents_path.read_text())
images = data.get("images")
if not isinstance(images, list) or not images:
    sys.exit("Contents.json: images array missing or empty")

at = "@"
expected = set()
for point, scale in [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]:
    if scale == 1:
        filename = f"icon_{point}x{point}.png"
    else:
        filename = f"icon_{point}x{point}{at}2x.png"
    expected.add((f"{point}x{point}", f"{scale}x", filename))

seen = set()
for entry in images:
    if not isinstance(entry, dict):
        sys.exit("Contents.json: non-object image entry")
    idiom = entry.get("idiom")
    size = entry.get("size")
    scale = entry.get("scale")
    filename = entry.get("filename")
    if idiom != "mac":
        sys.exit(f"Contents.json: expected idiom=mac, got {idiom!r} for {filename}")
    if not filename:
        sys.exit(f"Contents.json: missing filename for size={size} scale={scale}")
    key = (size, scale, filename)
    if key not in expected:
        sys.exit(f"Contents.json: unexpected mapping size={size} scale={scale} filename={filename}")
    if key in seen:
        sys.exit(f"Contents.json: duplicate mapping {key}")
    seen.add(key)

missing = expected - seen
if missing:
    pretty = ", ".join(f"{s}/{sc}/{f}" for s, sc, f in sorted(missing))
    sys.exit(f"Contents.json: missing mapping(s): {pretty}")

info = data.get("info") or {}
if info.get("version") != 1:
    sys.exit(f"Contents.json: expected info.version=1, got {info.get('version')!r}")
print(f"OK: Contents.json maps all {len(expected)} macOS AppIcon slots")
PYJSON

[[ -n "$expected_largest" ]] || fail "internal: missing 1024 slot name"
if ! cmp -s "$MASTER" "${ICONSET}/${expected_largest}"; then
  fail "${expected_largest} must be a byte-identical copy of Brand/AppIcon-1024.png"
fi
echo "OK: ${expected_largest} matches Brand/AppIcon-1024.png"

project_yml="${ROOT}/app/EditorAjar/project.yml"
[[ -f "$project_yml" ]] || fail "project.yml missing"
grep -Eq 'ASSETCATALOG_COMPILER_APPICON_NAME:[[:space:]]*AppIcon' "$project_yml" || \
  fail "project.yml must set ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon"
grep -Eq 'path:[[:space:]]*Resources' "$project_yml" || \
  fail "project.yml must include the Resources path for the asset catalog"
echo "OK: project.yml wires AppIcon + Resources"

echo "== SHA-256 manifest =="
if [[ "$WRITE_HASHES" -eq 1 ]]; then
  write_hash_manifest
fi

[[ -f "$MANIFEST" ]] || fail "SHA-256 manifest missing: ${MANIFEST#"$ROOT/"}; run scripts/generate-app-icon.sh --write-hashes or scripts/verify-app-icon.sh --write-hashes"

# Manifest must list exactly the expected relative paths (no extras, no missing).
expected_list=$(expected_rel_paths | sort)
manifest_paths=$(
  awk 'NF && $1 !~ /^#/ {
    $1 = ""
    sub(/^ +/, "")
    print
  }' "$MANIFEST" | sort
)

if [[ "$expected_list" != "$manifest_paths" ]]; then
  echo "ERROR: AppIcon.sha256 path set does not match the required asset set" >&2
  echo "--- expected ---" >&2
  echo "$expected_list" >&2
  echo "--- manifest ---" >&2
  echo "$manifest_paths" >&2
  exit 1
fi
echo "OK: manifest lists exactly the required $(echo "$expected_list" | wc -l | tr -d ' ') paths"

# Full-file hash check with stock shasum (paths relative to repo root).
if ! (
  cd "$ROOT"
  shasum -a 256 -c "${MANIFEST#"$ROOT/"}"
); then
  fail "SHA-256 mismatch (byte drift). If intentional: regenerate, then scripts/verify-app-icon.sh --write-hashes"
fi
echo "OK: all SHA-256 hashes match Brand/AppIcon.sha256"

echo "VERIFIED: AppIcon master + AppIcon.appiconset + SHA-256 manifest are complete and consistent"
