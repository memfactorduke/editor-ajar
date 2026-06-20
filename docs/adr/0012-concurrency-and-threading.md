# ADR-0012: Concurrency & threading model

- **Status:** Accepted
- **Date:** 2026-06-20
- **Deciders:** Mem
- **Tags:** concurrency, performance, stability, audio

## Context

The NFRs demand a 60 fps UI (NFR-PERF-006), real-time zero-drop playback (NFR-PERF-003), glitch-
free audio, and **no data races** (NFR-STAB-004) — simultaneously. These goals conflict if threads
contend or block each other, so the concurrency model must be explicit and enforced.

## Decision

- **Main thread = UI only.** It never performs disk/network I/O, decoding, or rendering. It reads
  immutable model snapshots and submits commands.
- **`ProjectStore` actor** owns the model; all edits serialize through it; it publishes immutable
  value snapshots (ADR-0008). Readers never lock.
- **Render executor = a priority queue.** *Interactive* requests (current playhead, scrub) preempt
  *background* requests (cache warming, render-in-place, proxy generation). Background work is
  cancelable and yields immediately to interactive work (FR-PLAY-007).
- **Audio render thread = real-time, lock-free, allocation-free** (FR-AUD-007). No Swift heap
  allocation, no locks, no Obj-C/Swift dynamic dispatch on the callback; parameters arrive via
  lock-free ring buffers/atomics. Audio is the A/V sync master.
- **Decode worker pool** is bounded and feeds the playback pipeline through bounded queues so a
  stall in one stage never stutters another.
- **Discipline:** use Swift Concurrency (`async`/`await`, actors) and `Sendable` checking for
  app/engine coordination; reserve raw threads/GCD for the real-time audio and display-link paths
  where Swift Concurrency's scheduling guarantees are insufficient.

The whole system must run **clean under Thread Sanitizer** in CI (NFR-STAB-004).

## Consequences

- Responsiveness and real-time guarantees are structural, not best-effort.
- Value-typed snapshots (ADR-0008) make cross-thread sharing safe without locks.
- **Costs:** the real-time audio constraints are strict and require care (pre-allocation, lock-free
  structures); mixing Swift Concurrency with real-time threads needs clear, documented boundaries.

## Alternatives considered

- **Locks around a shared mutable model.** Simple to write, but invites priority inversion, main-
  thread stalls, and data races — against NFR-STAB-004 and the latency budgets.
- **Everything on Swift Concurrency, including audio.** The cooperative thread pool doesn't meet
  hard real-time audio deadlines; the audio path must stay on a dedicated RT thread.
- **One big serial queue.** Couples interactive and background work; can't preempt.

## References

- [ARCHITECTURE §5, §7, §8](../ARCHITECTURE.md), SPEC §5, §6.8 (AUD), §6.12 (PLAY).
- [ADR-0008](0008-timeline-data-model.md), [ADR-0009](0009-render-graph-and-caching.md).
