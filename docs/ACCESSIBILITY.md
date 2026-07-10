# Editor Ajar — Accessibility checklist (NFR-A11Y-001)

> **Living document.** When you add an interactive control, add a row here and keep the
> VoiceOver label / keyboard path in sync with the source. CI enforces labels on **launch-
> visible** interactive AX roles via `EditorAjarAccessibilityTreeTests` (read-only tree walk).

**Requirement:** [SPEC NFR-A11Y-001](SPEC.md) — full keyboard control; VoiceOver labels on all
controls. Keyboard-first defaults are FCP/Premiere-familiar where practical.

**Regression net**

| Layer | What it covers | Where |
|-------|----------------|--------|
| Read-only AX tree walk | Every interactive role at launch has a non-empty label | `app/EditorAjar/UITests/EditorAjarAccessibilityTreeTests.swift` (ui-smoke) |
| Interaction smokes | Transport, tabs, inspector keyframe toggle, guides | `EditorAjarUISmokeTests` (ui-smoke) |
| Local-only canvas edit/nudge | FR-TXT-003 keyboard edit + drag/nudge | same file; **skipped on CI** (#210) |
| This checklist | Conditional panels, menus, shortcuts, tab order | human + PR review |

---

## Global keyboard map (transport / edit basics)

| Action | Shortcut | Notes |
|--------|----------|--------|
| Play / Pause | `Space` | Transport bar |
| Step backward / forward | `←` / `→` | One frame |
| Undo / Redo | `⌘Z` / `⇧⌘Z` | Edit menu |
| New Sequence | `⌘N` | Sequences menu + tab bar |
| Close Sequence | `⌘W` | When more than one sequence |
| Add Marker | `⇧⌘M` | Timeline + Markers menu |
| Previous / Next Marker | `⌘[` / `⌘]` | |
| Delete Marker | `⌘⌫` | Selected marker |
| Set Range In / Out | `I` / `O` | Timeline |
| Zoom timeline in / out | `⌘=` / `⌘-` | Timeline toolbar |
| Open export dialog | `⇧⌘E` | Header + Export menu |
| Toggle export queue | `⌃⌘E` | Header + Export menu |
| Enqueue active sequence export | `⌃⇧⌘E` | Export menu / queue panel |
| Edit canvas title | `⌥⌘E` | Title menu (primary visible box) |
| Nudge canvas title right / down | `⌥⌘→` / `⌥⌘↓` | Title menu (large step) |
| Toggle action/title-safe guides | `⌥⌘G` | Program monitor overlay |
| Copy / Paste grade | `⌥⌘C` / `⌥⌘V` | Clip menu |
| Save look | `⌥⌘L` | Clip menu |
| Cancel (sheets / banner dismiss) | `Esc` | Export dialog, read-only dismiss, title edit |

Full Keyboard Access (System Settings → Keyboard) tabs through buttons, fields, and toggles.
Arrow keys on a focused canvas title box nudge 1 unit (Shift = 10).

---

## Tab order (per surface)

Order is top-to-bottom, left-to-right within each chrome band (SwiftUI default).

1. **Read-only banner** (when visible) → Dismiss  
2. **Workspace header** → Export… → Exports / Hide Exports  
3. **Sequence tab bar** → sequence tabs (select, then per-tab close) → New Sequence → Close Sequence  
4. **Library panel** (static rows; not focus targets for edit)  
5. **Program monitor** → safe-area guides toggle → canvas title boxes (focusable) → transform handles when a clip is selected  
6. **Transport** → Step Backward → Play/Pause → Step Forward → Scrub slider  
7. **Inspector** → marker or transform fields when selection exists  
8. **Timeline toolbar** → tool buttons left-to-right  
9. **Timeline tracks** → track state buttons → clips → keyframe dots when shown  
10. **Export queue panel** (when visible) → Enqueue → Hide → per-job Pause/Resume/Cancel  

**Sheets:** Export dialog focuses Mode → Preset/Range/format pickers → Cancel → Validate.

---

## 1. Workspace chrome

| Control | Shortcut | AX label | AX value / hint |
|---------|----------|----------|-----------------|
| Header group | — | `Editor Ajar, {project summary}` | — |
| Export… | `⇧⌘E` | Open export dialog | id: `Open Export Dialog` |
| Exports / Hide Exports | `⌃⌘E` | Show export queue / Hide export queue | id: `Toggle Export Queue` |

---

## 2. Read-only project banner (FR-PROJ-005)

Visible when a project opens read-only (higher schema minor / ADR-0018).

| Control | Shortcut | AX label | AX value / hint |
|---------|----------|----------|-----------------|
| Banner | — | Read-only project notice | value: banner message |
| Dismiss | `Esc` | Dismiss read-only project notice | hint: hides banner only; editing stays disabled |

---

## 3. Sequence tab bar

| Control | Shortcut | AX label | AX value / hint |
|---------|----------|----------|-----------------|
| Tab bar | — | Sequence tab bar | id: `Sequence tab bar` |
| Sequence tab | click / Full Keyboard Access | Sequence tab {title} | Selected / Not selected |
| Close tab | — | Close {title} | disabled when sole sequence |
| New Sequence | `⌘N` | New Sequence | id: `New Sequence` |
| Close Sequence | `⌘W` | Close Sequence | id: `Close Sequence` |

---

## 4. Media / library panel

| Control | Shortcut | AX label | AX value / hint |
|---------|----------|----------|-----------------|
| Panel | — | Media and effects panel | — |
| Project Media row | — | Project Media | static placeholder (M2+) |
| Effects row | — | Effects | static placeholder |

No interactive pickers yet; when browser actions land, add rows here.

---

## 5. Program monitor / canvas (incl. FR-TXT-003, #187)

| Control | Shortcut | AX label | AX value / hint |
|---------|----------|----------|-----------------|
| Program monitor anchor | — | Program monitor showing {sequence} | image trait; id matches label |
| Safe-area guides toggle | `⌥⌘G` | Show/Hide Action and Title Safe Guides | On / Off; id: `Canvas Safe Area Guides Toggle` |
| Safe-area guides (when on) | — | Action-safe and title-safe guides | id: `Canvas Safe Area Guides` |
| Title text box (idle) | Return to edit; arrows nudge | Title text box {n}, {clip} | text + X/Y; id: `Canvas Title Text Box {uuid}` |
| Title editor (NSTextView) | Esc / ⌘↩ commit; Tab next | Title text box {n}, {clip} | id: `Canvas Title Editor {uuid}` |
| Transform overlay | — | Program Transform Overlay | when clip selected |
| Move / scale / rotate / anchor handles | drag; inspector for numeric | Move Transform / Scale Transform / … | button traits; inspector is keyboard path |
| Transform readout | — | Transform readout | value: X/Y/S/R summary |

**#210:** interactive canvas *edit* and *drag/nudge* XCUITests stay **local-only** (FocusState /
NSTextView / drag flakiness on headless CI). Labels for title boxes are covered by the AX walk.

---

## 6. Transport bar

| Control | Shortcut | AX label | AX value / hint |
|---------|----------|----------|-----------------|
| Transport group | — | Transport controls | id: `Transport controls` |
| Step Backward | `←` | Step Backward | id: `Step Backward` |
| Play / Pause | `Space` | Play or Pause | id matches label |
| Step Forward | `→` | Step Forward | id: `Step Forward` |
| Playhead readout | — | Playhead | value: frame description |
| Scrub playhead | slider / arrows step | Scrub playhead | value: playhead; hint mentions arrows |

---

## 7. Inspector

### Empty / summary

| Control | AX label |
|---------|----------|
| Inspector panel | Inspector panel |
| Sequence / Frame Rate / State rows | `{label}, {value}` |

### Marker inspector (marker selected)

| Control | Shortcut | AX label | id |
|---------|----------|----------|-----|
| Delete Marker | `⌘⌫` | Delete Marker | `Delete Marker` |
| Name field | — | Marker Name | `Marker Name` |
| Color picker | — | Marker Color | `Marker Color` |
| Note editor | — | Marker Note | `Marker Note` |

### Transform inspector (clip selected)

| Control | AX label | id / value |
|---------|----------|------------|
| Panel | Transform Inspector | id: `Transform Inspector` |
| Number fields | Position X, Scale X %, … | id: `Transform {title}` |
| Keyframe toggles | Add/Delete {param} Keyframe | id: `Transform {param} Keyframe Toggle` |
| Blend Mode | Blend Mode | id: `Transform Blend Mode` |
| Track compositing | Track Compositing Inspector | opacity + blend fields labelled |
| Flip Horizontal / Vertical | Flip Horizontal / Flip Vertical | On/Off; ids `Transform Flip Horizontal/Vertical` |

---

## 8. Timeline

| Control | Shortcut | AX label | Notes |
|---------|----------|----------|--------|
| Timeline group | — | Timeline | id: `Timeline` |
| Add Marker | `⇧⌘M` | Add Marker | |
| Previous / Next Marker | `⌘[` / `⌘]` | Previous/Next Marker | |
| Delete Marker | `⌘⌫` | Delete Marker | disabled if none selected |
| Detach Audio | — | Detach Audio | disabled if unlinked |
| Zoom Out / In | `⌘-` / `⌘=` | Zoom Timeline Out/In | |
| Track height − / + | — | Decrease/Increase Track Height | |
| Fit Timeline | — | Fit Timeline | |
| Zoom to Selection | — | Zoom to Selection | |
| Set Range In / Out | `I` / `O` | Set Range In/Out | |
| Clear Timeline Range | — | Clear Timeline Range | |
| Snapping toggle | — | Enable/Disable Snapping | dynamic title |
| Timeline ruler | drag scrub | Timeline ruler | value: playhead; markers as child buttons |
| Marker flag | click | Marker {name} | selection + color + frame + note |
| Track lane | — | Video/Audio track n, …states | contain track buttons |
| Enable/Lock/Hide/Mute/Solo | — | dynamic per track | value On/Off |
| Select all track | — | Select all {track} | |
| Clip | click | Clip {name} | selected + frame range |
| Keyframe lane / dots | click/drag | Transform keyframe lane … / {param} keyframe | frame value |

Footer: `Timeline status, {range}, {n} selected`.

---

## 9. Export dialog (#215)

Sheet; not present at launch (open with `⇧⌘E`).

| Control | Shortcut | AX label | value |
|---------|----------|----------|-------|
| Dialog | — | Export dialog | id: `Export Dialog` |
| Mode picker | — | Export mode | Video / Still frame / Audio only |
| Preset picker | — | Export preset | preset name (video mode) |
| Range picker | — | Export range | Whole timeline / In/out range |
| Still format | — | Still frame format | PNG / JPEG |
| Audio format | — | Audio-only format | WAV (PCM) / M4A (AAC) |
| Status | — | Export status: {msg} | when present |
| Cancel | `Esc` | Cancel export | id: `Export Dialog Cancel` |
| Validate | Return | Validate export settings | id: `Export Dialog Validate` |

---

## 10. Export queue panel (#216)

Toggled with `⌃⌘E`; empty list is the default when opened.

| Control | Shortcut | AX label | Notes |
|---------|----------|----------|--------|
| Panel | — | Export queue | id: `Export Queue Panel` |
| Enqueue Export Sequence | `⇧⌘E` (panel) / `⌃⇧⌘E` (menu) | Export active sequence | id: `Enqueue Export` |
| Hide | `Esc` (when focused) | Hide export queue | id: `Hide Export Queue` |
| Status / empty | — | Export queue status / No export jobs | |
| Job row | — | Export job {name} | state + progress value |
| Progress | — | Export progress for {name} | percent |
| Pause / Resume / Cancel | — | Pause/Resume/Cancel export {name} | state-dependent |

---

## 11. Relink / consolidate (#218)

**No dedicated interactive app chrome yet.** FR-MED-007/008 recovery is implemented in
`AjarMedia` / app model (bookmark reconcile, offline slate, relink + consolidate commands).
Playback shows a deterministic offline slate; there is no relink sheet or consolidate progress
panel in `app/EditorAjar/Sources/` as of this audit.

When UI lands, require:

- Every button/progress/list row: non-empty `accessibilityLabel` (+ value for progress/state)
- Keyboard: open, confirm, cancel, and progress dismissal without a pointer
- Rows in this checklist + coverage once visible at launch or via a dedicated UI smoke

---

## 12. Menus (not in window AX tree walk)

Menu commands still get `accessibilityLabel` for completeness; they are not walked by the
launch-time tree test.

| Menu | Items (labels) |
|------|----------------|
| Edit | Undo / Redo (dynamic titles) |
| Sequences | New Sequence, Close Sequence |
| Markers | Add / Previous / Next / Delete Marker |
| Clip | Copy/Paste Grade, Save Look, Apply Look…, Detach Audio |
| Title | Edit Canvas Title, Nudge Title Right/Down |
| Export | Open export dialog, Export Active Sequence, Show/Hide Export Queue |

---

## Maintaining the net

1. **New control** → label (+ identifier for tests) → shortcut if it is a basic edit/transport
   action → row in this file.
2. **Do not** force-gate interaction-heavy canvas paths on CI; prefer read-only AX assertions
   and local-only smokes (#210).
3. After app source changes, run:

```sh
xcodebuild -project app/EditorAjar/EditorAjar.xcodeproj -scheme EditorAjar \
  -testPlan EditorAjarCI -destination 'platform=macOS' \
  -only-testing:EditorAjarUITests/EditorAjarAccessibilityTreeTests test
```
