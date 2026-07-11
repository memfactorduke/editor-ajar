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
| Shuttle reverse / pause / forward | `J` / `K` / `L` | Repeated J/L stacks 1×, 2×, 4× |
| Loop In/Out range | `⇧⌘L` | Session-only; requires both marks |
| Jump to In / Out | `⌥I` / `⌥O` | |
| Previous / Next edit point | `⌘←` / `⌘→` | Clip heads and tails |
| Jump to start / end | `⇧⌘←` / `⇧⌘→` | Sequence bounds |
| Toggle alpha checkerboard | `⌥⌘B` | Display-only; export pixels unchanged |
| Full-screen program monitor | `⌃⌘F` | Native macOS window full screen |
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
| Toggle audio mixer | `⌥⌘M` | Header + Audio menu (FR-AUD-003) |
| Enqueue active sequence export | `⌃⇧⌘E` | Export menu / queue panel |
| Edit canvas title | `⌥⌘E` | Title menu (primary visible box) |
| Nudge canvas title right / down | `⌥⌘→` / `⌥⌘↓` | Title menu (large step) |
| Toggle action/title-safe guides | `⌥⌘G` | Program monitor overlay |
| Copy / Paste grade | `⌥⌘C` / `⌥⌘V` | Clip menu |
| Toggle blade tool / blade selected clip | `B` / `⌘B` | Timeline / Clip menu |
| Ripple delete / lift | `⇧⌫` / `⌫` | Timeline focus required |
| Copy / cut / paste clips | `⌘C` / `⌘X` / `⌘V` | Timeline focus required; text editors keep native clipboard — all Clip-menu commands disable while any text field or the canvas title editor has keyboard focus, so plain-key and clipboard shortcuts always reach the editor |
| Trim start / end to playhead | `[` / `]` | Clip menu |
| Slip earlier / later | `⌥[` / `⌥]` | One-frame keyboard equivalent |
| Slide earlier / later | `⌃⌥←` / `⌃⌥→` | One-frame keyboard equivalent |
| Insert / overwrite / append media | `F9` / `F10` / `E` | Selected media-browser item |
| Three-point insert / overwrite (fit marks) | `⇧F9` / `⇧F10` | Fits the media selection into the in/out marks (FR-TL-003); Clip menu |
| Replace selected clip source | `⌥⌘R` | Selected media-browser item |
| Select forward from playhead | `⇧⌘A` | Clip menu |
| Save look… | `⌥⌘L` | Clip menu → naming sheet |
| Toggle scopes | `⌥⌘S` | Clip menu / scopes panel |
| Apply / remove video transition | Clip → Transition | Needs abutting cut; typed refusal otherwise (FR-FX-001) |
| Cancel (sheets / banner dismiss) | `Esc` | Export dialog, import summary, save look, read-only dismiss, title edit |

Full Keyboard Access (System Settings → Keyboard) tabs through buttons, fields, and toggles.
Arrow keys on a focused canvas title box nudge 1 unit (Shift = 10).

---

## Tab order (per surface)

Order is top-to-bottom, left-to-right within each chrome band (SwiftUI default).

1. **Launch welcome** (when no project) → New Project → Open Project → recent projects  
2. **Read-only banner** (when visible) → Dismiss  
3. **Workspace header** → Mixer → Export… → Exports / Hide Exports  
4. **Sequence tab bar** → sequence tabs (select, then per-tab close) → New Sequence → Close Sequence  
5. **Media browser** → Import Media → layout → search → codec/state filters → media rows/cards → proxy/relink actions; VoiceOver navigation also exposes import progress  
6. **Program monitor** → safe-area guides toggle → canvas title boxes (focusable) → transform handles when a clip is selected  
7. **Scopes panel** (when visible, `⌥⌘S`) → type picker → hide  
8. **Transport** → Step Backward → Play/Pause → Step Forward → Scrub slider  
9. **Inspector** → marker, or Transform/Color/Audio/Effects tabs when a clip is selected  
10. **Timeline toolbar** → tool buttons left-to-right  
11. **Timeline tracks** → track state buttons → clips (waveforms / fade handles on audio) → keyframe dots when shown  
12. **Mixer panel** (when visible) → per-track fader / pan / mute / solo → master fader / meter  
13. **Export queue panel** (when visible) → Enqueue → Hide → per-job Pause/Resume/Cancel  

**Sheets:** New Project focuses Resolution → Frame Rate → Color Space → Audio Rate → Cancel →
Create. Export focuses Mode → Preset/Range/format pickers → Cancel → Validate. The import summary
exposes categorized result rows to VoiceOver, then the Done button to keyboard focus. Save Look
focuses Look name → Cancel → Save.

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

## 4. Media browser (FR-MED-005/009, #235)

| Control | Shortcut | AX label | AX value / hint |
|---------|----------|----------|-----------------|
| Panel / window drop target | Finder drag/drop | Media and effects panel. Drop media files or folders here to import. | Window accepts files and folders recursively |
| Import Media | `⌘I` via File menu / Full Keyboard Access | Import media files or folders | id: `Import Media` |
| List / grid layout | Full Keyboard Access | Media layout (explicit AX label; `labelsHidden`) | id: `Media Browser Layout` |
| Search | typing | Search media | id: `Media Search` |
| Codec / state filters | arrows / menu | Codec / State (explicit AX labels; `labelsHidden`) | All, offline, proxy-ready, proxy-pending |
| Project media row/card | click; drag to timeline | Media {filename} | codec, resolution, fps/VFR, duration, color space, offline and proxy state; id: `Media Row {uuid}` for list rows |
| Generate / Regenerate proxy | Full Keyboard Access | Generate / Regenerate | disabled while source is offline |
| Relink… | Full Keyboard Access | Relink… | offline items only; native single-file picker |
| Batch relink offline media | Full Keyboard Access | Batch relink offline media from a folder | id: `Batch Relink Offline Media`; visible when any offline item exists; folder picker → recursive filename+hash match |
| Import progress | — | Scanning folders… / Importing {filename} | `{completed} of {total} files`; id: `Media Import Progress` |
| Effects library | — | Effects library | id: `Effects Library`; search + Add / double-click appends to selected clip (FR-FX-002) |
| Effects search | typing | Search effects | id: `Effects Library Search` |
| Effect library row | double-click / Add | {name}, {category} | id: `Effect Library Row {kind}`; Add id: `Effect Library Add {kind}` |

The picker allows multiple files and folders. Folder enumeration, probing, hashing, and bookmark
creation run off the main actor; progress is non-modal so transport and other window controls remain
available.

Preview placeholders remain accessible while thumbnail/waveform cache work runs off-main. Hover
scrub is pointer enhancement only; the row metadata and timeline drag/drop are not hover-dependent.

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
| Shuttle Reverse / Pause / Forward | `J` / `K` / `L` | Playback menu commands | rate stacks on repeated J/L |
| Loop In/Out Range | `⇧⌘L` | Loop In/Out Range | session-only; no project schema field |
| Alpha checkerboard | `⌥⌘B` | Toggle Alpha Checkerboard | display-only |
| Program monitor full screen | `⌃⌘F` | Toggle Program Monitor Full Screen | native window full screen |

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
| Tab picker | Inspector tab | id: `Inspector Tab Picker` (Transform / Color / Audio) |
| Panel | Transform Inspector | id: `Transform Inspector` |
| Number fields | Position X, Scale X %, … | id: `Transform {title}` |
| Keyframe toggles | Add/Delete {param} Keyframe | id: `Transform {param} Keyframe Toggle` |
| Blend Mode | Blend Mode | id: `Transform Blend Mode` |
| Track compositing | Track Compositing Inspector | opacity + blend fields labelled |
| Flip Horizontal / Vertical | Flip Horizontal / Flip Vertical | On/Off; ids `Transform Flip Horizontal/Vertical` |

### Clip playback inspector (clip selected)

Nested inside the Transform tab's `ScrollView` (same clip-selected surface) so speed
controls cannot steal viewport height from transform fields and drop them from the AX tree.

| Control | AX label | id / notes |
|---------|----------|------------|
| Panel | Clip Playback Inspector | id: `Clip Playback Inspector` |
| Speed % | Speed % | id: `Speed %`; constant positive speed; ramps deferred to #247 |
| Reverse | Reverse | id: `Clip Reverse`; engine reverse sampler |
| Freeze Frame | Freeze Frame | id: `Clip Freeze Frame`; holds the clip source frame |

Audio scrubbing remains typed unavailable: the current live audio coordinator has no isolated,
non-real-time preview route. A UI toggle must not mutate or add work to the real-time audio callback
(ADR-0012). Loop and checkerboard state are deliberately session-only, so schema minor stays 13.

### Color inspector (clip selected, Color tab) — FR-COL-001/004/007

| Control | AX label | id / value |
|---------|----------|------------|
| Panel | Color Inspector | id: `Color Inspector` |
| Lift/Gamma/Gain RGB sliders | Lift R / Gamma G / … | id: `Color {Group} {R\|G\|B}` |
| Exposure…Vibrance sliders | Exposure, Contrast, … | id: `Color {title}` |
| Reset per-control / Reset All | Reset {name} / Reset All Color | id: `Color Reset …` |
| Import LUT… | Import cube LUT | id: `Import LUT` |
| LUT strength | Strength | id: `LUT Strength` |
| Remove LUT | Remove LUT | id: `Remove LUT` |
| Looks list Apply / Delete | Apply/Delete Look {name} | id: `Apply/Delete Look {uuid}` |
| Save Look… | Save Look from Selected Clip | id: `Save Look` → sheet |

Primary color grade is **static in v1** (no color keyframe toggles); transform keyframes remain on the Transform tab.

### Clip audio inspector (clip selected, Audio tab) — FR-AUD-001/002

| Control | AX label | id / notes |
|---------|----------|------------|
| Panel | Audio clip inspector | id: `Audio Clip Inspector` |
| Gain dB | Gain dB | id: `Clip Audio Gain dB`; static base; keyframe rubber-band deferred |
| Pan | Pan | id: `Clip Audio Pan` |
| Fade In (s) | Fade In (s) | id: `Clip Fade In Seconds` |
| Fade Out (s) | Fade Out (s) | id: `Clip Fade Out Seconds` |
| Add Crossfade | Add audio crossfade after selected clip | id: `Add Clip Audio Crossfade` |
| Remove Crossfade | Remove audio crossfade after selected clip | id: `Remove Clip Audio Crossfade` |

Selecting an audio clip auto-switches to the Audio tab; selecting a video clip leaves Color if
already there, otherwise restores Transform so existing ui-smoke identifiers stay reachable.

### Effects inspector (clip selected, Effects tab) — FR-FX-003 / FR-FX-001

| Control | AX label | id / notes |
|---------|----------|------------|
| Panel | Effects Inspector | id: `Effects Inspector` |
| Enable node | Enable {effect name} | id: `Effect Enable {nodeUUID}`; checkbox |
| Move up / down | Move Effect Up / Down | id: `Effect Move Up/Down {nodeUUID}` |
| Reset / Remove node | Reset/Remove {name} | id: `Effect Reset/Remove {nodeUUID}` |
| Parameter sliders | {param title} | id: `Effect Param {nodeUUID} {paramID}` |
| Mirror axis | Axis | id: `Effect Mirror Axis {nodeUUID}` |
| Reset stack | Reset Effects Stack | id: `Effects Reset All` |
| Transition section | Video Transition Inspector | id: `Transition Inspector` (cut after selected outgoing clip) |
| Transition kind / duration / direction | Kind / Duration (frames) / Direction | id: `Transition Kind` / `Transition Duration` / `Transition Direction` |
| Apply / Replace / Remove | Apply/Replace/Remove Transition | id: `Apply Transition` / `Remove Transition` |

Effect parameters are **static in v1** (engine stack animation exists; no effect-keyframe UI yet). Transitions require two abutting clips; non-adjacent apply is a typed refusal (FR-FX-001).

### Scopes panel (toggle `⌥⌘S`) — FR-COL-003

| Control | Shortcut | AX label | id |
|---------|----------|----------|-----|
| Panel | `⌥⌘S` | Scopes panel | `Scopes Panel` |
| Type picker | — | Scope type | `Scope Type Picker` |
| Display | — | {kind} scope | `Scope Display` |
| Hide | — | Hide Scopes | `Hide Scopes` |

Analysis is on-demand when paused and ≤ 10/s while playing (off the playback hot path).

### Save Look sheet (FR-COL-007)

| Control | AX label | id |
|---------|----------|-----|
| Sheet | Save Look dialog | `Save Look Sheet` |
| Name field | Look name | `Save Look Name` |
| Cancel / Save | Cancel / Save | `Save Look Cancel` / `Save Look Confirm` |

### Mixer panel (FR-AUD-003)

| Control | Shortcut | AX label | Notes |
|---------|----------|----------|--------|
| Toggle mixer | `⌥⌘M` | Show/Hide audio mixer | id: `Toggle Mixer` |
| Panel | Audio mixer panel | id: `Mixer Panel` |
| Track fader | arrows when focused | A{n} volume | id: `Mixer Track {uuid} Gain`; adjustable |
| Track pan | arrows when focused | A{n} pan | id: `Mixer Track {uuid} Pan` |
| Mute / Solo | — | Mute/Unmute / Solo/Unsolo A{n} | ids `Mixer Mute/Solo {uuid}` |
| Master fader | arrows when focused | Master volume | id: `Mixer Master Gain`; session monitoring |
| Meters | — | A{n} meter / Master meter | off-RT via `AudioMixerMeterAnalyzer` only |

Meters never observe the real-time audio callback; they are published from the
`org.editorajar.mixer-meter.analysis` queue (ADR-0012).

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
| Clip selection | click / `⌘`-click | Clip {name} | Command-click toggles multi-selection |
| Move clip | body drag; keyboard via cut/paste at playhead | Clip {name} | `⌥` momentarily unlinks; `⌃` disables snapping; vertical drag changes compatible unlocked track; dragging any clip in a multi-selection moves the whole selection (linked partners follow) in one undo step |
| Ripple / roll trim | edge drag / `[` and `]` | Clip {name} | plain edge drag ripples; `⌘` edge drag rolls; `⌥` momentarily unlinks; menu has exact playhead trims |
| Slip / slide | `⌥[` / `⌥]`; `⌃⌥←` / `⌃⌥→` | Clip menu | one-frame commands; repeat to adjust |
| Blade tool | `B`, then click clip / `⌘B` | Toggle Blade Tool | mouse click splits at the pointer position; `⌘B` blades the selected clip at the playhead (keyboard / VoiceOver path); a linked A/V clip blades together in one undo step |
| Three-point edit | `⇧F9` insert / `⇧F10` overwrite | Three-Point Insert/Overwrite Fit to Marks | fits the media-browser selection into the in/out marks; Clip menu; disabled without marks + selection |
| Snap indicator | — | Snapped at frame {n} | playhead, markers, clip edges, and transform keyframes; `⌃` disables during drag |
| Add/remove track | Sequence menu / Full Keyboard Access | menu item title | remove requires a selected empty track header |
| Marker flag | click | Marker {name} | selection + color + frame + note |
| Track lane | — | Video/Audio track n, …states | contain track buttons |
| Audio clip waveform | — | (decorative under clip label) | reuses #235 `AudioWaveformSummary` cache |
| Fade in handle | drag | Fade in handle | id: `Fade In Handle {clipID}` |
| Fade out handle | drag | Fade out handle | id: `Fade Out Handle {clipID}` |
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

## 12. Relink / consolidate (#218 / #246)

FR-MED-007 recovery UI (single-file + batch) is in the media browser and workspace. Consolidate
still has no dedicated progress chrome; engine commands remain in `AjarMedia`.

| Control | Shortcut | AX label | value / hint |
|---------|----------|----------|--------------|
| Relink… (per offline row) | Full Keyboard Access | Relink… | native single-file picker (movie/audio/image) |
| Batch Relink (library header) | Full Keyboard Access | Batch relink offline media from a folder | id: `Batch Relink Offline Media`; folder picker |
| Hash-mismatch alert | Default = Override | Media Does Not Match | Override (destructive) / Cancel; Override re-prepares with `.override` |
| Batch relink summary sheet | Return / Esc | Batch relink summary | id: `Batch Relink Summary`; relinked / unmatched counts + filenames |
| Close batch summary | Return | Done | id: `Close Batch Relink Summary` |

Provenance-aware single-file relink that must re-transcode surfaces FFmpeg install/failure
messages through the same typed mapping as import (`library.relink.retranscode.*` / import
FFmpeg guidance).

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

## 13b. First-media project settings proposal (FR-PROJ-003 / #246)

Shown after the first import into an empty project still on New Project sensible defaults, when
auto-detected settings differ from current. Apply is one undoable settings edit; Keep Current
leaves project settings unchanged.

| Control | Shortcut | AX label | value / hint |
|---------|----------|----------|--------------|
| Sheet | — | First media project settings proposal | id: `First Media Settings Proposal` |
| Proposed summary | — | Proposed settings | resolution, frame rate, color space, audio rate |
| Keep Current | Esc / cancel | Keep Current | id: `Decline First Media Settings` |
| Apply | Return | Apply | id: `Apply First Media Settings`; undoable |

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
| Clip | Copy/Paste Grade, Save Look, Apply Look…, Transition (apply kinds / Remove), Detach Audio |
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
