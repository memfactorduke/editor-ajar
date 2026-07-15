#!/usr/bin/env bash
# verify-compiled-app-icon.sh — fail-closed checks that a built EditorAjar.app
# actually compiled AppIcon (not merely that Assets.car exists).
#
# Inspects the compiled artifact only (AppIcon.icns + Assets.car + Info.plist).
# Does not read source .appiconset files.
#
# Prerequisites (macOS): /usr/bin/assetutil, iconutil, sips, file, python3,
# /usr/libexec/PlistBuddy.
#
# Usage:
#   scripts/verify-compiled-app-icon.sh --app /path/to/EditorAjar.app
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/verify-compiled-app-icon.sh --app /path/to/EditorAjar.app

Fail-closed check that the built app declares AppIcon and ships compiled
icon resources (nonempty AppIcon.icns that decodes, Assets.car with all
macOS AppIcon renditions via /usr/bin/assetutil --info).
EOF
}

app=""
while (($# > 0)); do
  case "$1" in
    --app)
      (($# >= 2)) || fail "--app requires a value"
      app=$2
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

[[ -n "$app" ]] || { usage >&2; fail "--app is required"; }
[[ -d "$app" ]] || fail "app bundle not found: $app"

plist="$app/Contents/Info.plist"
resources="$app/Contents/Resources"
icns="$resources/AppIcon.icns"
assets_car="$resources/Assets.car"

[[ -f "$plist" ]] || fail "missing Info.plist: $plist"
[[ -d "$resources" ]] || fail "missing Contents/Resources"

for tool in /usr/bin/assetutil iconutil sips file python3 /usr/libexec/PlistBuddy; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool unavailable: $tool"
done

icon_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$plist" 2>/dev/null || true)
[[ "$icon_name" == "AppIcon" ]] || \
  fail "CFBundleIconName must be AppIcon, got: ${icon_name:-<missing>}"
echo "OK: CFBundleIconName=AppIcon"

[[ -f "$icns" ]] || fail "missing compiled AppIcon.icns at Contents/Resources/AppIcon.icns"
[[ -s "$icns" ]] || fail "AppIcon.icns is empty"
file_out=$(file -b "$icns" || true)
case "$file_out" in
  *"Mac OS X icon"*|*"ICNS"*|*"icns"*) ;;
  *) fail "AppIcon.icns is not a Mac icon file (${file_out})" ;;
esac

# Single work directory for all temps (iconset extract + assetutil JSON); cleaned on EXIT.
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/editor-ajar-compiled-icon.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

# Decode every representation actool packed into the .icns (may be a subset of
# the catalog; the full ten slots are asserted via Assets.car below).
# iconutil requires the output path to end in ".iconset" and creates that directory.
iconset_path="${work_dir}/AppIcon.iconset"
iconutil_err="${work_dir}/iconutil.err"
if ! iconutil -c iconset "$icns" -o "$iconset_path" 2>"$iconutil_err"; then
  cat "$iconutil_err" >&2 || true
  fail "iconutil could not decode AppIcon.icns"
fi
[[ -d "$iconset_path" ]] || fail "iconutil did not create ${iconset_path}"
png_count=0
while IFS= read -r png; do
  [[ -z "$png" ]] && continue
  [[ -s "$png" ]] || fail "decoded icns entry is empty: $(basename "$png")"
  file_b=$(file -b "$png" || true)
  case "$file_b" in
    PNG*) ;;
    *) fail "decoded icns entry is not PNG (${file_b}): $(basename "$png")" ;;
  esac
  w=$(sips -g pixelWidth "$png" 2>/dev/null | awk '/pixelWidth/ {print $2}')
  h=$(sips -g pixelHeight "$png" 2>/dev/null | awk '/pixelHeight/ {print $2}')
  [[ -n "$w" && -n "$h" && "$w" == "$h" ]] || \
    fail "decoded icns PNG has invalid size ${w}x${h}: $(basename "$png")"
  [[ "$w" -ge 16 ]] || fail "decoded icns PNG too small (${w}px): $(basename "$png")"
  png_count=$((png_count + 1))
done <<EOF
$(find "$iconset_path" -type f -name '*.png' -print | sort)
EOF
[[ "$png_count" -ge 1 ]] || fail "iconutil produced no PNG representations from AppIcon.icns"
echo "OK: AppIcon.icns decodes to ${png_count} PNG representation(s)"

[[ -f "$assets_car" ]] || fail "missing Assets.car at Contents/Resources/Assets.car"
[[ -s "$assets_car" ]] || fail "Assets.car is empty"

# Fail-closed: Assets.car must contain Name=AppIcon with all ten catalog filenames
# and matching pixel dimensions (compiled artifact, not source tree).
assetutil_json="${work_dir}/assetutil-info.json"
if ! /usr/bin/assetutil --info "$assets_car" >"$assetutil_json" 2>/dev/null; then
  fail "assetutil --info failed on Assets.car"
fi
[[ -s "$assetutil_json" ]] || fail "assetutil --info produced empty output"

python3 - "$assetutil_json" <<'PYJSON'
import json, sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
if not isinstance(data, list):
    sys.exit("assetutil --info: expected a JSON array")

at = "@"
expected = {
    f"icon_16x16.png": (16, 16, 1),
    f"icon_16x16{at}2x.png": (32, 32, 2),
    f"icon_32x32.png": (32, 32, 1),
    f"icon_32x32{at}2x.png": (64, 64, 2),
    f"icon_128x128.png": (128, 128, 1),
    f"icon_128x128{at}2x.png": (256, 256, 2),
    f"icon_256x256.png": (256, 256, 1),
    f"icon_256x256{at}2x.png": (512, 512, 2),
    f"icon_512x512.png": (512, 512, 1),
    f"icon_512x512{at}2x.png": (1024, 1024, 2),
}

seen = {}
appicon_images = 0
for entry in data:
    if not isinstance(entry, dict):
        continue
    if entry.get("Name") != "AppIcon":
        continue
    if entry.get("AssetType") != "Icon Image":
        continue
    appicon_images += 1
    rendition = entry.get("RenditionName")
    if not rendition:
        sys.exit("Assets.car AppIcon Icon Image missing RenditionName")
    w = entry.get("PixelWidth")
    h = entry.get("PixelHeight")
    scale = entry.get("Scale")
    if rendition not in expected:
        sys.exit(f"Assets.car AppIcon has unexpected RenditionName: {rendition}")
    ew, eh, es = expected[rendition]
    if (w, h, scale) != (ew, eh, es):
        sys.exit(
            f"Assets.car {rendition}: expected {ew}x{eh} scale={es}, "
            f"got {w}x{h} scale={scale}"
        )
    if rendition in seen:
        sys.exit(f"Assets.car duplicate AppIcon rendition: {rendition}")
    seen[rendition] = True

if appicon_images == 0:
    sys.exit("Assets.car contains no AppIcon Icon Image assets (AppIcon not compiled)")

missing = sorted(set(expected) - set(seen))
if missing:
    sys.exit("Assets.car missing AppIcon rendition(s): " + ", ".join(missing))

print(f"OK: Assets.car contains AppIcon with all {len(expected)} macOS Icon Image renditions")
PYJSON

echo "VERIFIED: compiled AppIcon present in $(basename "$app")"
