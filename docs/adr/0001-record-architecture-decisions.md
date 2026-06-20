# ADR-0001: Record architecture decisions

- **Status:** Accepted
- **Date:** 2026-06-20
- **Deciders:** Mem
- **Tags:** process

## Context

Editor Ajar will be built largely by an autonomous coding loop with periodic human review. For
that to be safe, the *reasons* behind the architecture must be written down where both humans and
the agent can see them. Decisions made only in chat or implied by code are invisible to a fresh
agent run and tend to be silently re-litigated or violated.

## Decision

We will keep Architecture Decision Records in `docs/adr/`, one Markdown file per decision, using
the template in `0000-adr-template.md` (a light MADR variant). ADRs are numbered sequentially and
immutable once Accepted — a decision is changed by adding a new ADR that supersedes the old one,
not by editing it. The `docs/adr/README.md` index lists all ADRs and their status.

Accepted ADRs are **binding constraints** on implementation. The autonomous loop (ADR-0014) must
treat them as such and may not merge changes that contradict an Accepted ADR without a superseding
ADR.

## Consequences

- A durable, reviewable decision history that survives context resets and onboarding.
- A small discipline cost: non-trivial decisions require an ADR before or alongside the code.
- CI/process can reference ADRs (e.g. the dependency-rule check enforces ADR-0005).

## Alternatives considered

- **Decisions in the wiki / chat / PRs only** — not durable, not co-located with code, invisible
  to a fresh agent.
- **One big DECISIONS.md** — merges poorly, hard to reference a single decision by stable ID.

## References

- Michael Nygard, "Documenting Architecture Decisions"; the MADR format.
- [ARCHITECTURE](../ARCHITECTURE.md), [ADR-0014](0014-autonomous-build-loop.md).
