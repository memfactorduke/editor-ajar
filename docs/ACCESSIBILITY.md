# Editor Ajar — Accessibility checklist (NFR-A11Y-001)

> **Living document.** When you add an interactive control, add a row here and keep the
> VoiceOver label / keyboard path in sync with the source. CI enforces labels on launch-welcome
> and sample-workspace interactive AX roles via `EditorAjarAccessibilityTreeTests`.

**Requirement:** [SPEC NFR-A11Y-001](SPEC.md) — full keyboard control; VoiceOver labels on all
controls. Keyboard-first defaults are FCP/Premiere-familiar where practical.

**Regression net**

| Layer | What it covers | Where |
|-------|----------------|--------|
| AX tree walks | Every interactive role on the launch welcome and sample workspace has a non-empty label | `app/EditorAjar/UITests/EditorAjarAccessibilityTreeTests.swift` (ui-smoke) |
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
| Import media files / folders | `⌘I` | File menu; multi-select picker |
| New Project | `⌘N` | File menu + launch welcome |
| Open Project | `⌘O` | File menu + launch welcome |
| Save / Save As | `⌘S` / `⇧⌘S` | File menu; Save opens Save As for Untitled |
| New Sequence | `⌥⌘N` | Sequences menu + tab bar |
| Close Sequence | `⌘W` | When more than one sequence |
| Add Marker | `⇧⌘M` | Timeline + Markers menu |
| Previous / Next Marker | `⌘[` / `⌘]` | |
| Delete Marker | `⌘⌫` | Selected marker |
| Set Range In / Out | `I` / `O` | Timeline |
| Zoom timeline in / out | `⌘=` / `⌘-` | Timeline toolbar |
| Open export dialog | `⇧⌘E` | Header + Export menu |
| Toggle export queue | `⌃⌘E` | Header + Export menu |
| Toggle proxy / original playback | `⌥⌘P` | Header (FR-MED-004) |
| Enqueue active sequence export | `⌃⇧⌘E` | Export menu / queue panel |
| Edit canvas title | `⌥⌘E` | Title menu (primary visible box) |
| Nudge canvas title right / down | `⌥⌘→` / `⌥⌘↓` | Title menu (large step) |
| Toggle action/title-safe guides | `⌥⌘G` | Program monitor overlay |
| Copy / Paste grade | `⌥⌘C` / `⌥⌘V` | Clip menu |
| Save look | `⌥⌘L` | Clip menu |
| Cancel (sheets / banner dismiss) | `Esc` | Export dialog, import summary, read-only dismiss, title edit |

Full Keyboard Access (System Settings → Keyboard) tabs through buttons, fields, and toggles.
Arrow keys on a focused canvas title box nudge 1 unit (Shift = 10).

---

## Tab order (per surface)

Order is top-to-bottom, left-to-right within each chrome band (SwiftUI default).

1. **Launch welcome** (when no project) → New Project → Open Project → recent projects  
2. **Read-only banner** (when visible) → Dismiss  
3. **Workspace header** → Export… → Exports / Hide Exports  
4. **Sequence tab bar** → sequence tabs (select, then per-tab close) → New Sequence → Close Sequence  
5. **Library panel** → Import Media; VoiceOver navigation also exposes media rows and import progress  
6. **Program monitor** → safe-area guides toggle → canvas title boxes (focusable) → transform handles when a clip is selected  
7. **Transport** → Step Backward → Play/Pause → Step Forward → Scrub slider  
8. **Inspector** → marker or transform fields when selection exists  
9. **Timeline toolbar** → tool buttons left-to-right  
10. **Timeline tracks** → track state buttons → clips → keyframe dots when shown  
11. **Export queue panel** (when visible) → Enqueue → Hide → per-job Pause/Resume/Cancel  

**Sheets:** New Project focuses Resolution → Frame Rate → Color Space → Audio Rate → Cancel →
Create. Export focuses Mode → Preset/Range/format pickers → Cancel → Validate. The import summary
exposes categorized result rows to VoiceOver, then the Done button to keyboard focus.

---

## Document lifecycle (FR-PROJ-001/002/003, #233)

Launches to the welcome unless crash recovery has a project. The native window exposes the
package-derived title/represented URL and macOS edited indicator.

| Control | Shortcut | AX label | id / hint |
|---------|----------|----------|-----------|
| Welcome | — | Editor Ajar project welcome | id: `Welcome View` |
| New Project… | `⌘N` | Create a new project | id: `Welcome New Project` |
| Open… | `⌘O` | Open an existing project | id: `Welcome Open Project` |
| Recent project row | click / Full Keyboard Access | Open recent project {name} | id: `Recent Project {index}` |
| New Project sheet | — | New project settings | id: `New Project Settings` |
| Resolution | arrows / menu | Project resolution | id: `Project Resolution` |
| Frame Rate | arrows / menu | Project frame rate | id: `Project Frame Rate` |
| Color Space | arrows / menu | Project color space | id: `Project Color Space` |
| Audio Rate | arrows / menu | Project audio sample rate | id: `Project Audio Sample Rate` |
| Cancel | `Esc` | Cancel new project | id: `Cancel New Project` |
| Create | Return | Create new project | id: `Create New Project` |

New/Open/Sample replacement, window close, and app Quit all use the native unsaved-changes
confirmation buttons Save → Cancel → Discard Changes. Revert uses Revert → Cancel. Open/Save
panels carry localized titles/actions and retain security-scoped access after selection; Finder
Open With routes registered `.ajar` packages through the same open path. Full Keyboard Access
covers the standard AppKit controls in these dialogs.

---

## 1. Workspace chrome

| Control | Shortcut | AX label | AX value / hint |
|---------|----------|----------|-----------------|
| Header group | — | `Editor Ajar, {project summary}` | — |
| Export… | `⇧⌘E` | Open export dialog | id: `Open Export Dialog` |
| Exports / Hide Exports | `⌃⌘E` | Show export queue / Hide export queue | id: `Toggle Export Queue` |
| Proxy / Original playback | `⌥⌘P` | Proxy playback on / Original playback on | id: `Toggle Proxy Playback`; value `Proxy`/`Original`; hint: export always uses originals (FR-MED-004) |

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
| Panel / window drop target | Finder drag/drop | Media and effects panel. Drop media files or folders here to import. | Window accepts files and folders recursively |
| Import Media | `⌘I` via File menu / Full Keyboard Access | Import media files or folders | id: `Import Media` |
| Project media row | — | Media {filename} | codec or Offline |
| Import progress | — | Scanning folders… / Importing {filename} | `{completed} of {total} files`; id: `Media Import Progress` |
| Effects row | — | Effects | static placeholder |

The picker allows multiple files and folders. Folder enumeration, probing, hashing, and bookmark
creation run off the main actor; progress is non-modal so transport and other window controls remain
available.

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

## 11. Proxy playback (FR-MED-004)

- The header toggle is the working one-click proxy/original switch: it persists on the
  project, re-renders the program monitor, and selects ready proxies on the playback decode
  path when generation has completed.
- Missing or stale proxies fall back to originals and enqueue real background generation
  (`ProxyGenerationQueue` + ProRes 422 Proxy under `caches/proxies/`); progress is
  session-only in the model.
- VoiceOver announces the current mode via label + value; the hint states that export always
  uses originals regardless of the toggle.
- Media-pool status row UI is deferred: the library panel is a placeholder with no per-item
  list to attach none/generating/ready/failed labels to (state is durable on `MediaRef` and
  becomes visible once a media list lands).

## 12. Relink / consolidate (#218)

**No dedicated interactive app chrome yet.** FR-MED-007/008 recovery is implemented in
`AjarMedia` / app model (bookmark reconcile, offline slate, relink + consolidate commands).
Playback shows a deterministic offline slate; there is no relink sheet or consolidate progress
panel in `app/EditorAjar/Sources/` as of this audit.

When UI lands, require:

- Every button/progress/list row: non-empty `accessibilityLabel` (+ value for progress/state)
- Keyboard: open, confirm, cancel, and progress dismissal without a pointer
- Rows in this checklist + coverage once visible at launch or via a dedicated UI smoke

## 13. Media import summary (FR-MED-001 / FR-MED-010)

Sheet shown after every completed import batch. Imported VFR files appear in both Imported and
Variable Frame Rate Conformed sections so the successful import and timebase decision are explicit.

| Control | Shortcut | AX label | value / hint |
|---------|----------|----------|--------------|
| Sheet | — | Media import summary | id: `Media Import Summary` |
| Imported row | — | Imported: {filename} | codec + dimensions/audio-only |
| Skipped duplicate row | — | Skipped Duplicates: {filename} | existing source/bookmark kept |
| VFR-conformed row | — | Variable Frame Rate Conformed: {filename} | stable timebase |
| Failed row | — | Failed: {filename} | localized typed reason; unsupported text names the missing FFmpeg fallback |
| Done | `Return` / `Esc` | Close media import summary | id: `Close Media Import Summary` |

---

## 14. Menus (not in window AX tree walk)

Menu commands still get `accessibilityLabel` for completeness; they are not walked by the
launch-time tree test.

| Menu | Items (labels) |
|------|----------------|
| File | New Project (`⌘N`), Open, Recent Projects, Import Media… (`⌘I`), Save, Save As, Revert to Saved |
| Edit | Undo / Redo (dynamic titles) |
| Sequences | New Sequence, Close Sequence |
| Markers | Add / Previous / Next / Delete Marker |
| Clip | Copy/Paste Grade, Save Look, Apply Look…, Detach Audio |
| Title | Edit Canvas Title, Nudge Title Right/Down |
| Export | Open export dialog, Export Active Sequence, Show/Hide Export Queue |
| Help | Open Sample Project |

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
