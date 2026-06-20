# ADR-0004: License — GPLv3-or-later

- **Status:** Accepted
- **Date:** 2026-06-20
- **Deciders:** Mem
- **Tags:** licensing, distribution, community

## Context

Editor Ajar is positioned as a genuine **open-source alternative** to commercial consumer editors.
The license choice affects (a) whether the project and its forks must stay open, (b) which
dependencies we can bundle (notably FFmpeg builds and codec libraries like x264/x265, which are
GPL), and (c) the plugin ecosystem (ADR-0013). The serious open-source editors in this space
(Shotcut, Kdenlive, and Blender more broadly) are GPL, which both fits the ethos and eases codec
bundling.

## Decision

We will license Editor Ajar under **GPLv3-or-later** (`SPDX: GPL-3.0-or-later`). The full text is
in `/LICENSE`. Source files carry the standard short header. Contributions are accepted under the
project license (inbound = outbound); we may adopt a lightweight Developer Certificate of Origin
rather than a CLA to keep contribution friction low and the project un-relicensable by any single
party.

## Consequences

- The project and all distributed forks/derivatives stay open — aligned with the mission.
- We can bundle GPL-compatible codec components (e.g. x264/x265) and GPL FFmpeg builds where
  needed, consistent with the import-boundary design (ADR-0003).
- **Plugins:** under GPLv3, plugins that link against the app are expected to be GPL-compatible.
  This shapes ADR-0013 (the plugin API) and means we will not support closed-source plugins.
  (Blender shows a GPL project can still have a thriving ecosystem.)
- We must keep dependency licenses compatible (no GPL-incompatible libraries in distributed
  binaries); a license-check step belongs in CI.
- Apple framework usage is fine (system libraries); we ship our own source under GPLv3.

## Alternatives considered

- **MPL-2.0 (file-level copyleft).** Allows proprietary add-ons/plugins; weaker guarantee that
  improvements return to the project. A reasonable middle ground, but less aligned with a "stays
  open" alternative and complicates bundling GPL codecs.
- **MIT / Apache-2.0 (permissive).** Maximum adoption and a friendlier base for commercial
  plugins (Apache adds patent protection), but permits closed forks and restricts bundling GPL
  codecs. Chosen against because keeping the project open is a stated goal.

## References

- SPEC §2 (principle 6), §9 (`.ajar` openness), §10 (third-party).
- [ADR-0003](0003-media-engine.md), [ADR-0013](0013-plugin-architecture.md).
- `LICENSE` (GPLv3 full text).
