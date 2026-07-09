# ADR-0018: Schema minor versioning and forward-compatible opens

- **Status:** Accepted
- **Date:** 2026-07-09
- **Deciders:** Mem
- **Tags:** persistence, format, stability, effects, compatibility
- **Supersedes:** ADR-0007 versioning clause (single integer + “newer = read-only”);
  ADR-0016 §1 unknown-kind sentence (“unknown future kinds are a decode error until a
  migration exists”)

## Context

ADR-0007 promised that opening a newer project in an older build is **read-only with a clear
message** (FR-PROJ-005). In practice `schemaVersion` stayed at `2` while additive persisted
fields landed behind `decodeIfPresent` + defaults. An older build therefore opens a *newer*
document as fully editable, silently drops unknown keys, and **destroys that data on resave**.

Separately, ADR-0016 made unknown `ClipEffectKind` cases hard decode failures. When FR-FX-002
adds library kinds, older builds would refuse to open such projects entirely instead of opening
them read-only.

## Decision

### 1. Major + minor schema components

The project document and media manifest each carry:

| Field | Role |
|-------|------|
| `schemaVersion` | **Major** — breaking document shape changes. |
| `schemaMinor` | **Minor** — additive persisted fields or enum kinds. Default `0` when absent. |

`AjarCore` publishes `currentSchemaVersion` (major) and `currentSchemaMinor` (minor). Every save
writes both at the build’s current values. **Every additive persisted field or new enum kind
bumps `currentSchemaMinor`.** Breaking shape changes bump major and reset minor to `0` under a
migration ADR.

This change itself is additive: `currentSchemaMinor = 1` (introduces the minor field).

### 2. Open policy (FR-PROJ-005)

| File vs build | Behavior |
|---------------|----------|
| **Higher major** | **Refuse open** with a typed error and clear message. Do not attempt full document decode when the probed major is unsupported (breaking shapes must not partially load). |
| **Same major, higher minor** | **Open read-only**: decode succeeds for additive-compatible shapes; editing commands are refused with a typed error; **resave is blocked** so unknown keys / future data cannot be stripped. |
| **Same major, same or lower minor** | Normal **editable** open (lower minor may be migrated / rewritten on next save). |
| **Lower major** | Existing forward-migration path; result is editable at the build’s current major. |

### 3. Simplest sound design for unknown effect kinds

We do **not** introduce an opaque preserved form for unknown `ClipEffectKind` in this slice.
Discipline is:

1. **Bump `schemaMinor` whenever a new kind (or other persisted shape) is added.** An older
   build that implements this ADR probes minor first and opens same-major / higher-minor
   projects **read-only** before edit/resave can strip data. Additive-only higher-minor files
   decode fully via existing `decodeIfPresent` defaults.
2. If decode still encounters an unknown kind (forgotten minor bump, corrupted file, or a build
   that predates this ADR opening a post-kind file), fail with a **typed** codec error whose
   message states that the project likely needs a newer Editor Ajar — not a bare
   `DecodingError`.

Full “decode unknown nodes as opaque payloads and round-trip them under read-only” remains a
future option if FR-FX-002 needs display of unrecognized nodes; it is not required to stop data
loss once resave and edits are blocked on higher minor.

### 4. Open API surface

`AjarProjectCodec.decode` continues to return `AjarProjectLoadResult`:

- `.editable(Project)`
- `.readOnly(Project, reason: AjarProjectReadOnlyReason)`

`AjarProjectReadOnlyReason` covers higher **minor** (and keeps a clear user-facing message).
Higher **major** is a `AjarProjectCodecError`, not a read-only open.

Callers that save or apply edits must thread the open mode: `encode` / package writes refuse
read-only opens; `EditHistory` (session entry for undoable edits) refuses commands against a
read-only open with a typed error. UI may surface the reason message; core never traps.

**No default `openMode` on persist.** `AjarProjectCodec.encode(_:openMode:)` and
`AjarAutosaveStore.writeSnapshot` require an explicit mode so
`encode(loadResult.project)` cannot silently rewrite a higher-minor file. In-memory first saves
use `encodeNewDocument(_:)`. **Recovery** decodes the full load result: read-only snapshots skip
journal replay and return the snapshot project with its mode intact.

## Consequences

- FR-PROJ-005 is enforceable: newer additive work cannot be silently destroyed by older builds
  that ship this ADR.
- Authors of additive schema changes must bump `currentSchemaMinor` (reviewable, testable).
- Older builds that never learned minor still strip unknown keys; that is unfixable without
  shipping this gate — the fix is forward-looking.
- **Costs:** every open path should preserve `AjarProjectLoadResult` / open mode through to
  edit and save; CLI/app layers that currently discard read-only must adopt the mode (tracked
  as follow-up if not landed in the same slice).

## Alternatives considered

- **Keep a single integer; treat any higher value as read-only.** Failed in practice because the
  integer never moved for additive fields.
- **Opaque unknown effect nodes always.** Correct for perfect fidelity, but larger model and
  render-surface change than needed to stop data loss; deferred.
- **Soft-decode unknown kinds to empty / drop.** Silently loses creative work; rejected
  (same failure mode as unknown keys).

## References

- FR-PROJ-005 (SPEC §6.14); NFR-STAB-002 / NFR-STAB-003.
- [ADR-0007](0007-project-file-format.md), [ADR-0016](0016-effects-and-transitions.md).
- Issue #193 (follow-up from #180 review).
