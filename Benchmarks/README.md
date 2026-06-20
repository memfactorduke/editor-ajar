# Benchmarks

The performance benchmark harness that gates merges (SPEC §5, [docs/PERFORMANCE.md](../docs/PERFORMANCE.md),
ADR-0011). Benchmarks run via the `ajar` CLI on the reference machine and fail CI on regression
beyond the noise band.

Planned coverage: launch/open latency, playback (zero dropped frames at target specs), scrub/seek
latency, per-effect GPU cost, export throughput, memory footprint.

_Empty until ROADMAP M2 — this README marks the intended location. Results are git-ignored._
