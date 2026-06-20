# ADR-0014: Autonomous build-loop readiness

- **Status:** Accepted (readiness principles) — concrete harness deferred
- **Date:** 2026-06-20
- **Deciders:** Mem
- **Tags:** process, autonomy, ci

## Context

Editor Ajar is intended to be built largely by an **autonomous coding loop** (an agent that picks
work, implements it, verifies it, and integrates it, iterating without manual babysitting), with a
human (Mem) as orchestrator/reviewer. The *mechanics* of that loop are being decided later, but the
**repository must be ready for it now** — retrofitting loop-readiness is expensive, while building
it in costs nothing today. This ADR records the readiness decisions and the loop's intended shape;
a future ADR will finalize the harness.

## Decision

The repository is structured so an autonomous loop can make safe, verifiable progress:

1. **Single sources of truth, machine-readable:** [SPEC](../SPEC.md) (requirements with stable
   IDs), [ROADMAP](../ROADMAP.md) (ordered milestones), and the [ADRs](.) (binding constraints).
   The loop selects the lowest incomplete milestone, decomposes it into tasks tagged with
   requirement IDs, and implements them.
2. **An objective Definition of Done** (TESTING §4) and **ordered CI gates** (ADR-0011) make
   "merge-eligible" machine-checkable — covering correctness, visuals/audio, **performance**, and
   stability. The loop may not merge against a failing gate or a contradicting Accepted ADR.
3. **Headless verifiability** (ADR-0005): most work is checked by fast unit/property tests and the
   `ajar` CLI golden-frame/benchmark harness — no GUI automation required for the bulk of progress.
4. **Loop-facing guidance lives in `CLAUDE.md`** at the repo root: conventions, where the SoT docs
   are, how to run tests/benchmarks, the DoD, and "never do" rules (e.g. don't update goldens/
   baselines to make a test pass; don't violate the dependency rule; don't put work on the audio RT
   path that allocates).
5. **Default oversight posture (initial):** the agent works on branches and opens PRs; **CI must be
   green and a human approves the merge.** This is the safest starting point; we may later allow
   test-gated auto-merge or milestone-checkpoint autonomy — each such change is its own ADR.

## Consequences

- The repo can be handed to the loop the moment the harness is wired, with strong guardrails.
- Progress is auditable: every merged change references requirement IDs and passes the gates.
- **Costs / open questions (for the future harness ADR):** the loop runner itself (orchestration,
  task queue under `docs/loop/`, retry/escalation policy), the merge-autonomy level, and
  cost/time budgets per task are deliberately **not** decided here.

## Alternatives considered

- **Decide the full loop now.** Premature — the orchestrator (Mem) chose to set up the repo first.
  We capture readiness without over-committing.
- **No loop-specific structure.** Would force an expensive retrofit (testability, traceability,
  agent guide) later.

## References

- [ADR-0005](0005-core-ui-separation.md), [ADR-0011](0011-testing-and-quality-gates.md),
  [ROADMAP "How the loop uses this file"](../ROADMAP.md), `../../CLAUDE.md`.
