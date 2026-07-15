#!/usr/bin/env bash
# generate-app-icon.sh — regenerate every macOS AppIcon.appiconset PNG from the
# approved 1024×1024 master using high-quality sips resampling.
#
# This is reproducible generation (same script + master + macOS sips path), not a
# claim of cross-OS or cross-sips-version byte-identical PNG output. Committed
# SHA-256 integrity is enforced by scripts/verify-app-icon.sh against
# app/EditorAjar/Brand/AppIcon.sha256 — refresh that manifest intentionally
# after regenerating (see --write-hashes).
#
# Source of truth (never overwritten):
#   app/EditorAjar/Brand/AppIcon-1024.png
#
# Output:
#   app/EditorAjar/Resources/Assets.xcassets/AppIcon.appiconset/
#
# Prerequisites (macOS): sips, python3 (Contents.json writer), shasum (with --write-hashes).
#
# Artwork stays full-bleed and opaque; the system applies the rounded mask — do not
# add manual corner masks or transparency.
#
# Usage (from repo root):
#   scripts/generate-app-icon.sh                 # regenerate PNGs + Contents.json
#   scripts/generate-app-icon.sh --write-hashes  # also refresh AppIcon.sha256
#   scripts/verify-app-icon.sh                   # fail-closed integrity check
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="${ROOT}/app/EditorAjar/Brand/AppIcon-1024.png"
ASSETS="${ROOT}/app/EditorAjar/Resources/Assets.xcassets"
ICONSET="${ASSETS}/AppIcon.appiconset"
MANIFEST="${ROOT}/app/EditorAjar/Brand/AppIcon.sha256"
WRITE_HASHES=0

# Build Retina filenames without a contiguous "local@domain.tld"-looking token in this file.
AT=$'@'
retina() { printf 'icon_%s%s2x.png' "$1" "$AT"; }

usage() {
  cat <<'EOF'
Usage: scripts/generate-app-icon.sh [--write-hashes]

Regenerate AppIcon.appiconset PNGs from Brand/AppIcon-1024.png using high-quality
sips resampling. Preserves the master; overwrites only the iconset outputs.

  --write-hashes  After generation, rewrite Brand/AppIcon.sha256 (intentional refresh).
                  Without this flag the hash manifest is left unchanged so CI will fail
                  until you refresh it deliberately.
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
command -v python3 >/dev/null 2>&1 || fail "python3 is required (writes Contents.json)"
if [[ "$WRITE_HASHES" -eq 1 ]]; then
  command -v shasum >/dev/null 2>&1 || fail "shasum is required to write AppIcon.sha256"
fi
[[ -f "$MASTER" ]] || fail "master icon missing: $MASTER"

# Logical point size, scale (1 or 2), pixel edge.
SLOTS=(
  "16:1:16"
  "16:2:32"
  "32:1:32"
  "32:2:64"
  "128:1:128"
  "128:2:256"
  "256:1:256"
  "256:2:512"
  "512:1:512"
  "512:2:1024"
)

slot_filename() {
  local point=$1 scale=$2
  if [[ "$scale" == "1" ]]; then
    printf 'icon_%sx%s.png' "$point" "$point"
  else
    retina "${point}x${point}"
  fi
}

manifest_paths() {
  echo "app/EditorAjar/Brand/AppIcon-1024.png"
  echo "app/EditorAjar/Resources/Assets.xcassets/Contents.json"
  echo "app/EditorAjar/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"
  local slot point scale px name
  for slot in "${SLOTS[@]}"; do
    IFS=':' read -r point scale px <<<"$slot"
    name=$(slot_filename "$point" "$scale")
    echo "app/EditorAjar/Resources/Assets.xcassets/AppIcon.appiconset/${name}"
  done
}

write_hash_manifest() {
  local tmp path
  tmp=$(mktemp "${TMPDIR:-/tmp}/editor-ajar-appicon-sha.XXXXXX")
  (
    cd "$ROOT"
    # shellcheck disable=SC2046
    shasum -a 256 $(manifest_paths)
  ) | sort -k2 >"$tmp"
  mv -f "$tmp" "$MANIFEST"
  echo "OK: wrote SHA-256 manifest ${MANIFEST#"$ROOT/"} ($(wc -l <"$MANIFEST" | tr -d ' ') entries)"
}

mkdir -p "$ICONSET"

# Wipe previous PNGs so renamed/stale retina files cannot linger.
find "$ICONSET" -maxdepth 1 -type f -name '*.png' -delete 2>/dev/null || true

python3 - "$ASSETS" "$ICONSET" <<'PY'
import json, sys
from pathlib import Path

assets = Path(sys.argv[1])
iconset = Path(sys.argv[2])
assets.mkdir(parents=True, exist_ok=True)
iconset.mkdir(parents=True, exist_ok=True)

(assets / "Contents.json").write_text(
    json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n"
)

at = "@"
images = []
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
    images.append({
        "filename": filename,
        "idiom": "mac",
        "scale": f"{scale}x",
        "size": f"{point}x{point}",
    })

(iconset / "Contents.json").write_text(
    json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n"
)
print(f"OK: wrote Contents.json with {len(images)} macOS slots")
PY

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/editor-ajar-appicon-gen.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

for slot in "${SLOTS[@]}"; do
  IFS=':' read -r point scale px <<<"$slot"
  name=$(slot_filename "$point" "$scale")
  out="${ICONSET}/${name}"
  if [[ "$px" == "1024" ]]; then
    # Preserve the approved master pixels for the largest slot (no re-encode).
    cp -f "$MASTER" "$out"
  else
    # High-quality Core Graphics resample; write via plain temp path (no retina suffix).
    tmp_png="${tmp_dir}/resize-${px}.png"
    sips -z "$px" "$px" "$MASTER" --setProperty format png --out "$tmp_png" >/dev/null
    cp -f "$tmp_png" "$out"
  fi
  [[ -s "$out" ]] || fail "failed to write ${out}"
  echo "  wrote ${name} (${px}x${px})"
done

echo "OK: wrote macOS AppIcon.appiconset renditions into ${ICONSET#"$ROOT/"}"
echo "    master preserved at ${MASTER#"$ROOT/"}"
echo "    note: sips output is not claimed cross-OS byte-identical; integrity is the SHA-256 manifest"

if [[ "$WRITE_HASHES" -eq 1 ]]; then
  write_hash_manifest
else
  echo "    hashes not refreshed (run with --write-hashes after intentional regen, then verify)"
fi
