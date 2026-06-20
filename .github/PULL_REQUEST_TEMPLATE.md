<!-- Thanks for contributing to Editor Ajar! Keep PRs small and focused. -->

## What & why

<!-- What does this change do, and which requirement(s) does it satisfy? -->

Requirement IDs: <!-- e.g. FR-KEY-003, NFR-PERF-003 -->
Roadmap milestone: <!-- e.g. M4 -->

## Definition of Done (see docs/TESTING.md §4)

- [ ] Targeted requirement ID(s) are met and **referenced in the new tests**
- [ ] New `AjarCore` logic has unit/property tests; pixel/audio changes have golden tests
- [ ] **Benchmarks stay green** — no gated NFR (SPEC §5) regresses beyond its noise band
- [ ] New UI is keyboard-accessible and VoiceOver-labelled (if applicable)
- [ ] Lint + format clean; sanitizers clean
- [ ] `AjarCore` adds no UI/GPU/AV imports (ADR-0005) and no force-unwrap/`try!`/`fatalError` (NFR-STAB-003)
- [ ] Docs and `CHANGELOG.md` updated
- [ ] If this changes a decision: a superseding ADR is included

## Notes for reviewers

<!-- Anything tricky? Performance measurements? Screenshots/clips for UI? -->
