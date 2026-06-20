# ADR-0013: Plugin architecture (Metal shader + parameter manifest)

- **Status:** Accepted (target v1.x)
- **Date:** 2026-06-20
- **Deciders:** Mem
- **Tags:** plugins, extensibility, rendering, stability, licensing

## Context

The SPEC calls for a plugin API for third-party effects/generators/transitions (FR-FX-006). Plugins
must run in the same GPU-resident pipeline without CPU readback (FR-FX-007), must not be able to
destabilize the host (NFR-STAB), and must respect the project license (ADR-0004). We want this
designed-for from the start even though it ships in v1.x.

## Decision

A plugin is a package declaring a **parameter manifest** (typed, keyframable parameters with
ranges/defaults/UI hints) plus one or more **Metal shaders**. The host instantiates a plugin as an
**effect node in the render graph** (ADR-0009): it receives input texture(s) and resolved parameter
values for the frame, and returns an output texture. Plugins:

- run inside the host's Metal pipeline (no CPU readback; they fit the per-node cost budget),
- **cannot access the project model, the file system, or the network** (sandboxed capability set),
- integrate automatically with keyframing (parameters are `Animatable`) and caching (they
  participate in content hashing — a plugin must declare a deterministic hash of its parameters).

A built-in effect uses the *same* internal contract, so the effect library and plugins share one
mechanism. Licensing: consistent with GPLv3 (ADR-0004), plugins linking the host are expected to be
GPL-compatible; this is documented for plugin authors.

## Consequences

- Extensibility without compromising performance, determinism, or stability.
- The effect library and third-party plugins share one tested abstraction.
- **Costs:** we must define and version a stable plugin ABI/manifest and a sandbox; determinism
  requires plugins to hash parameters honestly (validated/tested). Full sandbox hardening is part
  of the v1.x plugin work.

## Alternatives considered

- **Arbitrary native code plugins (dylibs with full access).** Maximum power, but a crash/security/
  determinism hazard — a misbehaving plugin could violate NFR-STAB; rejected.
- **Scripting-language effects (CPU).** Easy to author, but CPU readback breaks the perf budget
  (FR-FX-007).
- **No plugin API.** Simplest, but forecloses an ecosystem the SPEC wants.

## References

- SPEC §6.10 (FX), §6.4 (KEY). [ARCHITECTURE §11](../ARCHITECTURE.md).
- [ADR-0004](0004-license-gplv3.md), [ADR-0006](0006-gpu-compositing-metal.md),
  [ADR-0009](0009-render-graph-and-caching.md).
