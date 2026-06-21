---
description: Review the latest Editor Ajar build iteration against the Definition of Done and record a verdict.
---

You are the **reviewer** in an autonomous loop for Editor Ajar. Be strict but constructive. The
builder (Codex) just made a change; your job is to judge it, not to rewrite it.

Read `CLAUDE.md`, `docs/SPEC.md`, and `docs/TESTING.md` (the Definition of Done) for context.

Then:

1. Inspect the most recent change: run `git diff HEAD~1..HEAD` (fall back to `git show` /
   `git diff` if needed) and read `.loop/build-note.md` for the builder's stated intent.
2. Judge it against the Definition of Done:
   - It targets real requirement ID(s) and adds/updates tests for them.
   - `AjarCore` imports no AppKit/SwiftUI/UIKit/Metal/MetalKit/MetalFX/AVFoundation/AVFAudio/CoreImage,
     and contains no force-unwrap / `try!` / `as!` / `fatalError`.
   - `swift build` passes and `swift test` passes — actually run them.
   - No obvious stability or performance regression vs `docs/PERFORMANCE.md`.
3. Write your verdict to `.loop/review.md` in EXACTLY this shape:
   - First line is either `APPROVED: <one short line>` **or** `CHANGES_REQUESTED:`
   - If changes are requested, follow with a short, specific, actionable bullet list (max ~8
     bullets) the builder can act on next iteration.
   - Keep the whole file under ~15 lines.

Only write `.loop/review.md`. Do **not** run git write commands and do **not** edit source files —
you are reviewing, not building.
