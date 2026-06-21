# Benchmarks

This directory tracks report-only performance benchmarks for SPEC §5,
[docs/PERFORMANCE.md](../docs/PERFORMANCE.md), and ADR-0011. The harness runs through the `ajar`
CLI so local runs and CI exercise the same code path.

Run the current suite:

```sh
scripts/bench.sh
```

Run one metric:

```sh
scripts/bench.sh single-frame-render-seek-latency
```

Current metrics:

| Metric | Requirement | Unit |
| --- | --- | --- |
| `cold-start-proxy` | NFR-PERF-001 | ms |
| `project-open-decode-load` | NFR-PERF-002 | ms |
| `single-frame-render-seek-latency` | NFR-PERF-005 | ms |

`baseline.json` is the first synthetic-fixture baseline for human review. CI prints fresh benchmark
JSON, but regression gating is deferred until a stable reference machine exists. Once that runner is
available, the gate should compare against this baseline with the ADR-0011 noise band instead of
failing hosted CI on machine-to-machine variance.
