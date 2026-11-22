# Actape

macOS app (SwiftUI, macOS 26.4 / Tahoe) that records global mouse + keyboard events via `CGEventTap` and replays them via `CGEvent.post`. Bundle id `com.rizetngan.actape`.

## Build / run

- Open `Actape.xcodeproj` in Xcode and run, **or**
- CLI: `xcodebuild -project Actape.xcodeproj -scheme Actape -configuration Debug -destination 'platform=macOS' build`
- Build product: `~/Library/Developer/Xcode/DerivedData/Actape-*/Build/Products/Debug/Actape.app` — launch with `open <path>`.

## Architecture

The Xcode project uses `PBXFileSystemSynchronizedRootGroup` — **anything dropped into `Actape/` is auto-included in the build**, no `project.pbxproj` edits needed. Don't put `.entitlements` inside `Actape/` (it would be bundled as a resource); keep it at the project root.

Layered, single-responsibility:

- [Actape/Models/](Actape/Models/) — `Macro`, `MacroEvent` (single struct with optional fields per `MacroEventKind`, hand-rolled `Codable` via `decodeIfPresent` so adding fields won't break saved macros), `KeyCodeNames` (HIToolbox virtual-key → human label). `MacroEventKind.click` is the default recorded mouse action — a coalesced press+release at a point (see recorder/player below); the raw `.mouseDown`/`.mouseUp` kinds still exist so a user can manually split a click. `MacroEvent` also has a synthetic `.typeText` "programmable type" kind (never recorded, only user-added): a `text` template (`{n}` placeholder + `\t`/`\n`/`\r` escapes) plus a `SequenceFormat` counter (`number` / `timeHHMM` / `timeColon`) computed as `seqStart + seqStep * iteration` (time values are minutes-since-midnight, wrapped mod 1440). `renderedText(iteration:)` produces the per-iteration string; `iteration` advances once per macro repeat. Time sequences can set `seqStopEnabled` + `seqStop` (a stop time-of-day); `sequenceStopDecision(iteration:)` returns `(type, halt)` and handles wrapping past 23:59 — the player halts the whole run when it fires. The seq/render helpers are `nonisolated` (called from the off-main playback thread).
- [Actape/Recording/EventRecorder.swift](Actape/Recording/EventRecorder.swift) — listen-only `cgSessionEventTap` on the main runloop. Filters the global toggle hotkeys via `blockedKeyCodes` (set from `HotkeyPreferences`, default F6/F7) so toggling record doesn't pollute the recording. **Coalesces a `mouseDown`+`mouseUp` pair into one `.click`**: a down is held in `pendingDown` and only emitted once its fate is known — a matching up *within `clickMaxHoldMs` (150 ms)* makes a `.click` (down's pre-delay + max click count); a longer hold keeps the literal `Mouse Down` + `Mouse Up` (so press-and-hold survives, hold = up's delay); and a drag/key/scroll/stop flushes the held down as a literal `Mouse Down` first (preserving drags and manual sequences). Reaching the up branch with a matching pending-down implies no movement occurred, so the up's delay is exactly the hold time. Re-enables the tap on `tapDisabledByTimeout` / `tapDisabledByUserInput`.
- [Actape/Playback/EventPlayer.swift](Actape/Playback/EventPlayer.swift) — `Task.detached` loop, posts via `.cghidEventTap`, scales inter-step delays by `playbackSpeed`, honors `repeatCount` (0 = infinite — surfaced as the "Loop forever" checkbox in the detail header; live loop counter shown in the bottom status bar). A `.click` posts down then up separated by a fixed `clickHoldMicros` (30 ms) that is **not** scaled by speed, so a click never stays stuck-down when slowed. `.mouseDrag` is distance-gated: the loop threads the last cursor point into `post(...)`, and `postDrag` walks a long jump in `dragStepPx` (24 pt) steps so synthesized/authored drags register — dense recorded samples (a few px apart) stay a single post, unchanged. Tracks a per-step `iterations[event.id]` counter passed to `post(event:iteration:)`; `.typeText` steps type each char via `keyboardSetUnicodeString` (layout-independent) with a 2 ms inter-char gap, and can halt the whole run early via `sequenceStopDecision`.
- [Actape/Hotkeys/](Actape/Hotkeys/) — `HotkeyManager` (Carbon `RegisterEventHotKey` singleton; C-callback hops to main via `DispatchQueue.main.async`; `setBindings(_:)` atomically replaces all registrations). `HotkeyPreferences` is the `@MainActor ObservableObject` holding the two configurable shortcuts (`HotkeyConfig` = keyCode + Carbon modifier mask), persisted to `UserDefaults`; `ActapeApp.applyHotkeys()` re-registers and updates the recorder's blocked keys on launch and on any change.
- [Actape/Store/MacroStore.swift](Actape/Store/MacroStore.swift) — `@MainActor` `ObservableObject` orchestrator. Persists to `~/Library/Application Support/Actape/macros.json` (debounced). Also drives file `exportToFile(_:suggestedName:)` / `importFromFile()` via `NSSavePanel`/`NSOpenPanel` (JSON; import assigns fresh IDs and appends).
- [Actape/AccessibilityHelper.swift](Actape/AccessibilityHelper.swift) — `AXIsProcessTrustedWithOptions` + deep link to System Settings.
- UI: [ContentView.swift](Actape/ContentView.swift) (split view + Record/Play toolbar in `.primaryAction` + AX banner + bottom status bar showing state and live loop/step), [Views/MacroDetailView.swift](Actape/Views/MacroDetailView.swift) (two-tier header: name/summary, then REPEAT + SPEED controls), [Views/EventRowView.swift](Actape/Views/EventRowView.swift) (expandable inline editor), [Views/SettingsView.swift](Actape/Views/SettingsView.swift) (the `Settings` scene — global-shortcut recorder rows).

## Permissions & entitlements (load-bearing)

- **Sandbox is OFF.** [Actape.entitlements](Actape.entitlements) sets `com.apple.security.app-sandbox = false`. Required because a sandboxed app cannot create a session-level `CGEventTap` that observes other apps, nor post events into them. `ENABLE_APP_SANDBOX = NO` is set in both Debug/Release in `project.pbxproj`. Don't re-enable it without a plan.
- **Hardened runtime stays ON** — works fine alongside an unsandboxed AX-using app.
- Runtime requires Accessibility access in System Settings → Privacy & Security → Accessibility. The app shows a yellow banner and re-checks every 2s if absent.

## Hotkeys

Global toggle shortcuts are **user-configurable** in Settings (⌘,) and persisted to `UserDefaults`; defaults are **F6** (toggle recording) and **F7** (toggle playback). The in-app menu also exposes ⌘⇧R (record) and ⌘⇧P (play), and ⌘O / ⌘⇧E for import / export.

The recorder filters the configured shortcuts by **keycode** (via `HotkeyPreferences.blockedKeyCodes`). Function keys are the recommended choice: a letter-based shortcut means that letter can't be captured while recording. To change the *defaults*, edit `HotkeyPreferences.defaultRecord` / `.defaultPlay` — registration and blocked-key wiring follow automatically through `ActapeApp.applyHotkeys()`.

## Concurrency notes

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so types are MainActor by default. Two specific places step off main and need to stay that way:

- `EventRecorder`'s `CGEvent.tapCreate` C-callback runs on the runloop thread (we attach to main, so it's main, but the closure is C-bridged) — uses `MainActor.assumeIsolated` to get back into actor land.
- `EventPlayer.post(event:)` is `nonisolated static` and called from `Task.detached` so the playback loop doesn't hop to main between every event. Don't add MainActor APIs to it.

## Testing notes

- **Don't drive Actape's UI with `~/.claude/bin/macos-control` while recording or playing back.** The recorder will capture the test-driver's clicks/keystrokes, and during playback the cursor fights the broker. Test interactively, or test against a *different* app while Actape records.
- Persisted macros live at `~/Library/Application Support/Actape/macros.json` — delete to reset state between tests.
