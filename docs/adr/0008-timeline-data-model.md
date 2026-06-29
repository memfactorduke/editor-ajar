# ADR-0008: Timeline data model — immutable values + command reducer + rational time

- **Status:** Accepted
- **Date:** 2026-06-20
- **Deciders:** Mem
- **Tags:** model, editing, undo, concurrency, stability

## Context

The data model is the heart of `AjarCore`. It must support unbounded undo/redo (FR-TL-012), safe
concurrent access between the UI and render/audio threads (ADR-0012), exact frame math without
drift, deterministic behavior for testing (ADR-0011), and clean serialization (ADR-0007).

## Decision

1. **Immutable value types.** `Project`, `Sequence`, `Track`, `Clip`, etc. are Swift value types
   (`struct`/`enum`). An edit produces a *new* `Project` value rather than mutating in place.
2. **Command reducer.** Edits are expressed as `EditCommand` values applied by a pure function
   `apply(_ command: EditCommand, to: Project) throws -> Project`. The ordered command log is the
   undo/redo stack; redo replays, undo restores the prior value (cheap via structural sharing).
3. **Rational time everywhere.** Time is `RationalTime` (value/timescale, like `CMTime`) — never
   floating-point frame counts — so edits, speed maps, and frame lookups are exact.
4. **A serializing `ProjectStore` actor** owns the current value and publishes immutable snapshots
   to readers (UI, render-graph builder). Mutations go through the actor; readers get a consistent
   snapshot without locks (ADR-0012).
5. **Invariants enforced centrally:** clips on a track never overlap and stay sorted; compound
   clips can't contain themselves (FR-CMP-005); links stay consistent. Violations are programmer
   errors caught by tests, not by crashing on user input.
6. **Compound clips reference sequences by ID.** The clip stores a `ClipSource.sequence(id:)`
   reference, not a copy of the nested timeline. Duration and timebase are resolved from the
   referenced sequence at query time, and the validator rejects direct or transitive cycles before
   a project can be edited or saved.

## Consequences

- Undo/redo is almost free and provably correct (property test: `undo ∘ apply == identity`).
- Snapshots are safe to hand to other threads (value semantics), enabling lock-free reads on the
  render path (ADR-0012) and deterministic rendering (ADR-0009/0011).
- The same model serializes directly to `.ajar` (ADR-0007).
- **Costs:** structural sharing/copy-on-write needs care for large sequences to keep edits within
  the keystroke-latency budget (NFR-PERF-007); we measure this and optimize hot structures (e.g.
  persistent/indexed collections) if needed.

## Alternatives considered

- **Mutable reference-type object graph (classic OOP).** Familiar, but undo becomes manual and
  error-prone, and sharing across threads needs locks → data-race risk (against NFR-STAB-004).
- **Full event-sourcing/CRDT.** Powerful for collaboration, but overkill for single-user v1 and
  heavier to test; the command log gives us the undo benefits without the complexity.
- **Floating-point time.** Simpler arithmetic but accumulates drift and breaks frame-exact tests.

## References

- SPEC §6.2 (TL), §6.6 (CMP). [ARCHITECTURE §3](../ARCHITECTURE.md).
- [ADR-0009](0009-render-graph-and-caching.md), [ADR-0012](0012-concurrency-and-threading.md),
  [ADR-0007](0007-project-file-format.md).
