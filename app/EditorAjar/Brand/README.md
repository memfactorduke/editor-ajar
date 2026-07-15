# Brand assets — App Icon

## Artwork source

`AppIcon-1024.png` is the approved **1024×1024** master for the Editor Ajar macOS application
icon. It was generated specifically for Editor Ajar with the built-in OpenAI image-generation
tool from an original prompt describing a door left ajar (openness + video editing), a dark
neutral full-bleed tile, and a restrained cool accent. It contains **no third-party art or
marks**, no text, and no watermark.

The master is **flattened, opaque, and full-bleed**. Apple’s current macOS guidance allows a
square 1024 master; the system applies the rounded mask. Do **not** add manual corner masks or
transparency.

## Prerequisites

On macOS (CI and local):

- `sips` — high-quality resize of catalog PNGs
- `python3` — writes/checks `Contents.json` and inspects compiled `Assets.car` JSON
- `shasum` — SHA-256 manifest (`Brand/AppIcon.sha256`)
- `file` — PNG / ICNS type checks
- For compiled-bundle checks: `/usr/bin/assetutil`, `iconutil`, `/usr/libexec/PlistBuddy`

## Regeneration (reproducible generation + committed hash integrity)

From the repository root:

```sh
# Regenerate catalog PNGs from the master (sips path is reproducible on macOS; not claimed
# cross-OS / cross-sips-version byte-identical).
scripts/generate-app-icon.sh

# Intentionally refresh the SHA-256 manifest after reviewing the new pixels:
scripts/generate-app-icon.sh --write-hashes
# equivalent after a manual catalog edit that already passed structural checks:
# scripts/verify-app-icon.sh --write-hashes
```

That script high-quality-resamples every smaller macOS `AppIcon.appiconset` PNG from the master
and writes:

```text
app/EditorAjar/Resources/Assets.xcassets/AppIcon.appiconset/
```

The master path is never overwritten. The 512@2x slot is a byte-identical copy of the master.

**Integrity:** `Brand/AppIcon.sha256` pins full-file SHA-256 of the master, every rendered PNG,
and both catalog JSON files. CI / `scripts/lint.sh` run `scripts/verify-app-icon.sh`, which
fails on any byte drift, missing path, or extra iconset PNG. Do **not** refresh hashes to
silence a failure unless the artwork change is intentional and reviewed.

## Verification (offline)

```sh
scripts/verify-app-icon.sh
```

Checks structure (names, dimensions, Contents.json mappings, opacity of the master) **and**
full-file SHA-256 against `Brand/AppIcon.sha256` via stock `shasum -a 256 -c`.

Compiled apps (Debug/Release) are checked with:

```sh
scripts/verify-compiled-app-icon.sh --app /path/to/EditorAjar.app
```

(nonempty `AppIcon.icns` that `iconutil` can decode; `Assets.car` must list all ten macOS
AppIcon renditions via `/usr/bin/assetutil --info`). The release artifact verifier calls this
on the packaged app.

## Xcode wiring

The asset catalog is included via XcodeGen — edit `app/EditorAjar/project.yml` (Resources path +
`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`), then regenerate; never hand-edit the generated
project as the source of truth:

```sh
xcodegen --spec app/EditorAjar/project.yml --project app/EditorAjar
```
