# ADR-0007: `.ajar` project file format

- **Status:** Accepted
- **Date:** 2026-06-20
- **Deciders:** Mem
- **Tags:** persistence, format, stability, openness

## Context

The project format must be **open and inspectable** (SPEC principle 6), **never lose work**
(NFR-STAB-002), survive media moves (FR-PROJ-004), be **versioned and migratable**
(FR-PROJ-005), and hold sidecar resources (proxies, render cache, version snapshots) without
embedding the user's media by default (FR-MED-008).

## Decision

A project is a **macOS package directory** with the `.ajar` extension (a bundle that presents as a
single document in Finder):

```
MyProject.ajar/
  project.json        # versioned, canonical-key-order JSON: the document (diff-friendly)
  media.json          # MediaRef manifest: stable UUID + bookmark/URL + content hash + metadata
  transcodes/         # durable import-boundary ProRes 422 + PCM working media
  caches/             # proxies + render cache (machine-local; NOT part of project identity)
  versions/           # rolling save snapshots (keep N)
  thumbnails/         # cached thumbnails/waveforms
```

- The **document** (`project.json` + `media.json`) is the same Codable model used at runtime in
  `AjarCore`; serialization is canonical (stable key order, normalized numbers) so projects are
  **text-diffable** and merge-friendlier.
- Media is **referenced, not embedded** by default; security-scoped bookmarks + content hashes
  enable robust relink. "Consolidate" copies media into the package on request.
- The format carries a **schema version**; `AjarCore` owns forward-migration. Opening a newer
  project in an older build is read-only with a clear message (FR-PROJ-005).
- Save is **atomic** (write-to-temp + rename); auto-save + a command journal back crash recovery
  (NFR-STAB-002).

## Amendment — 2026-07-11: fallback-transcode storage

Import-boundary fallback movies live in the package's top-level `transcodes/` directory, named
`<original-sha256>-prores422.mov`. They are durable working media, not disposable cache entries,
so they do not belong in `caches/`. `MediaRef.sourceURL` points to the native working movie while
optional provenance retains the original URL and original SHA-256; `contentHash` also remains the
original hash so re-import deduplicates before doing transcode work. Publication is a same-folder
temporary-file rename, and cancellation removes the temporary output.

This additive `MediaRef` provenance shape advances ADR-0018 `schemaMinor` from 12 to 13. Legacy
references decode with no provenance (nested optional/default decode), and current encoding writes
the nested value only for fallback-transcoded sources.

## Consequences

- Human-readable, diffable, inspectable projects; no lock-in.
- Caches and snapshots travel with the project but are excluded from its identity/versioning.
- **Costs:** packages need careful atomic-write and bookmark handling; JSON is larger than a
  binary blob (acceptable; gzip optional). If profiling shows large projects are slow to load
  (NFR-PERF-002), we may add an optional binary/SQLite sidecar **without** changing the canonical
  JSON as the source of truth — that would be a new ADR.

## Alternatives considered

- **Single binary file (e.g. SQLite or a custom blob).** Fast and compact, but opaque and not
  diffable — against the openness principle. Revisitable as an *optional* cache, not the format.
- **XML (FCPXML-like).** Verbose; we prefer JSON ergonomics. NLE-interchange import is a separate
  future concern (SPEC §13).
- **Embed media by default.** Huge files, slow saves; rejected — referencing + consolidate-on-
  demand is better.

## References

- SPEC §9, §6.14 (PROJ), §6.1 (MED). [ADR-0008](0008-timeline-data-model.md).
