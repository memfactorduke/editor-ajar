# Editor Ajar consumer release operations

This guide separates two intentionally different outputs:

- **Unsigned test package:** proves that a clean checkout builds, packages, and carries the right
  version, macOS 14 deployment floor, and arm64 executable. It is named and marked
  `UNSIGNED-TEST-ONLY` and must never be offered as a consumer download.
- **Production package:** requires Developer ID signing with hardened runtime, Apple notarization,
  stapling, `codesign` verification, `spctl` (Gatekeeper) acceptance, and `stapler` validation.
  Any missing or invalid production input stops the command before a release artifact is emitted.

Normal contributor builds remain unsigned. No Apple account, certificate, or secret is needed for
`swift build`, `swift test`, ordinary Xcode builds, or the unsigned packaging check.

## Local unsigned build and deterministic verification

From a clean checkout on a Mac with Xcode 26 or newer:

```sh
scripts/package-release.sh --mode unsigned --version 1.1.0
```

The command archives the checked-in Xcode project in Release mode, forces the required arm64 slice
and macOS 14 deployment target, packages it, and immediately runs the independent verifier. It
creates:

```text
dist/EditorAjar-1.1.0-macOS-arm64-UNSIGNED-TEST-ONLY.zip
```

Expected final output has this shape:

```text
OK: unsigned/test-only label present; no Developer ID signature accepted.
OK: CFBundleIconName=AppIcon
OK: AppIcon.icns decodes to N PNG representation(s)
OK: Assets.car contains AppIcon with all 10 macOS Icon Image renditions
VERIFIED: compiled AppIcon present in EditorAjar.app
OK: bundle version 1.1.0 (build 1) matches release version 1.1.0.
OK: minimum macOS 14.0 and architectures [arm64] match SPEC.
VERIFIED: EditorAjar-1.1.0-macOS-arm64-UNSIGNED-TEST-ONLY.zip (unsigned)
ARTIFACT: .../dist/EditorAjar-1.1.0-macOS-arm64-UNSIGNED-TEST-ONLY.zip
```

To rerun only the deterministic checks:

```sh
scripts/verify-release-artifact.sh \
  --artifact dist/EditorAjar-1.1.0-macOS-arm64-UNSIGNED-TEST-ONLY.zip \
  --version 1.1.0 \
  --mode unsigned
```

The command refuses to replace an existing local artifact. Remove the old local `dist` file
explicitly if a new test build is intended.

## Production credentials

Production releases use an App Store Connect API key for notarization. Do not put any credential,
base64 payload, `.p8`, `.p12`, password, or temporary keychain in the repository.

| GitHub Actions secret | Meaning |
|---|---|
| `APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64 of the exported Developer ID Application certificate and private key (`.p12`) |
| `APPLE_DEVELOPER_ID_APPLICATION_P12_PASSWORD` | Password used when exporting that `.p12` |
| `APPLE_TEAM_ID` | Apple Developer team identifier embedded in the certificate |
| `APPLE_NOTARY_KEY_P8_BASE64` | Base64 of the App Store Connect API private key (`AuthKey_….p8`) |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect API issuer ID |

Create the GitHub environments named exactly `consumer-release` and `release-dry-run`. Store all
six secrets only in `consumer-release`, require reviewer approval there, and leave
`release-dry-run` without production credentials. Protect release tags separately; the workflow
verifies that the checked-out commit matches the selected tag, but repository tag protection is
what prevents an authorized maintainer from moving that tag. Rotate credentials immediately if a
workflow log or machine exposes their contents.

For a local production run, import the Developer ID Application identity into the login or a
temporary keychain, keep the `.p8` outside the repository, and export only these non-repository
environment values:

```sh
export APPLE_SIGNING_IDENTITY='Developer ID Application: Example Name (TEAMID1234)'
# Optional when the identity lives outside the normal keychain search list:
export APPLE_SIGNING_KEYCHAIN="$HOME/Library/Keychains/release.keychain-db"
export APPLE_TEAM_ID='TEAMID1234'
export APPLE_NOTARY_KEY_PATH="$HOME/private/AuthKey_EXAMPLE.p8"
export APPLE_NOTARY_KEY_ID='EXAMPLE123'
export APPLE_NOTARY_ISSUER_ID='00000000-0000-0000-0000-000000000000'
```

## Production procedure

1. Confirm all ordinary CI gates are green. Run the full one-hour release soak described in
   `docs/TESTING.md`; this packaging workflow does not weaken or replace any existing quality gate.
2. Create and push a new protected semantic-version tag such as `v1.1.0` at the reviewed commit.
3. In GitHub Actions, run **Consumer Release** for that tag in `production` mode, or let the tag
   push trigger it. The workflow checks out the tag commit, imports the certificate into a
   temporary keychain, calls the production packaging command, and removes temporary credentials
   even after failure.
4. The production command requires a clean checkout whose `HEAD` exactly matches the tag. It signs
   with Developer ID Application and hardened runtime, waits for an `Accepted` notarization result,
   staples the ticket, then runs all three final security checks.
5. Only after all checks pass does the workflow create a draft GitHub release and upload
   `EditorAjar-X.Y.Z-macOS-arm64.zip`. It makes the release public only after that upload succeeds.
   If any GitHub release already exists for the tag, the workflow stops instead of overwriting or
   silently replacing an asset. Production ZIPs are not also exposed through the temporary
   Actions-artifact channel.
6. Download the GitHub asset onto a clean, supported Apple Silicon Mac, unzip it, and open it from
   Finder. That independent Gatekeeper check is the external consumer-distribution completion gate.

Equivalent local production command, from the clean tag checkout after setting the environment
variables above:

```sh
scripts/package-release.sh --mode production --release-tag v1.1.0 --build-number 1
```

Expected production verification ends with:

```text
...: accepted
source=Notarized Developer ID
OK: Developer ID signature, hardened runtime, stapling, and Gatekeeper accepted.
OK: bundle version 1.1.0 (build 1) matches release version 1.1.0.
OK: minimum macOS 14.0 and architectures [arm64] match SPEC.
VERIFIED: EditorAjar-1.1.0-macOS-arm64.zip (production)
```

## Failure and rollback

- **Before upload:** fix the certificate, API key, version/tag, or notarization rejection and run
  again. The command leaves no production artifact when a security check fails.
- **Existing release/tag:** the workflow deliberately refuses to overwrite it. Inspect the
  existing release before taking any action. Never move a version tag that users may have fetched;
  make the fix and publish a higher patch version instead.
- **Bad release discovered after publishing:** immediately convert the GitHub release to a draft:
  `gh release edit vX.Y.Z --draft`. Preserve logs and the rejected binary for diagnosis. After the
  fix passes the full gates, publish a new patch tag. Asset deletion, if policy requires it, must be
  a separate explicit operator action (`gh release delete-asset vX.Y.Z FILE --yes`); the workflow
  never performs it.
- **Credential exposure:** draft the release, rotate/revoke the exposed App Store Connect key and
  Developer ID material through Apple, replace the GitHub secrets, and rebuild under a new patch
  tag. Apple notarization tickets cannot be treated as a substitute for credential rotation.

Pipeline readiness is not consumer-distribution completion. Completion requires real provisioned
credentials and a downloaded production artifact that Gatekeeper accepts on a clean supported Mac.
