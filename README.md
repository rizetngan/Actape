# Macrobot

[简体中文说明 / 简体中文 README](README.zh-CN.md)

> The macOS direct side-button build was tested with a physical mouse. Windows support is under development. Hold-to-repeat mode is **not** yet implemented in the macOS build.


A lightweight macOS app for recording and replaying mouse + keyboard macros. It
captures global input via a `CGEventTap` and plays it back with `CGEvent.post`,
so it can drive any app — not just itself.

![Macrobot main window](docs/screenshot.png)

## Features

- **Record clicks, drags, scrolls, and keystrokes** system-wide with one hotkey.
- **Clean, editable steps.** Recordings collapse into readable steps you can edit
  inline — adjust coordinates, buttons, click counts, delays, or reorder by drag.
- **Smart click capture.** A quick press becomes a single *Click* step (which
  always releases promptly, even when slowed down); a long press stays a real
  press-and-hold; movement is recorded as a drag.
- **Adjustable playback.** Set a repeat count or loop forever, and scale the whole
  macro's speed from 0.1× to 10×.
- **Programmable "Type Text" steps** with an auto-incrementing counter — numbers or
  24-hour timestamps (e.g. type `0000`, `0015`, `0030`… once per loop), with an
  optional stop time that halts the run.
- **Configurable global shortcuts** for record and play (default **F6** / **F7**).
- **Import / export** macros as JSON, and automatic persistence between launches.

## Direct mouse side-button macro trigger (custom fork)

This branch adds a built-in mouse side-button listener; no separate mouse remapping app is required. Open a macro, click **Bind button…**, then press the physical mouse side button you want to use. The assignment is saved with the macro and can be cleared or reassigned. During normal use, pressing the bound side button runs the recorded macro directly (press again to stop playback). The original Back/Forward action of the mapped side button is suppressed.

The implementation listens for macOS CoreGraphics extra mouse button events, so buttons transformed into keyboard shortcuts by vendor firmware/software may need a separate compatibility path.

For architecture, build and manual acceptance checks, see [docs/MOUSE_BUTTON_TRIGGER.md](docs/MOUSE_BUTTON_TRIGGER.md). The original MIT license is retained.

## Download

**Custom fork:** build this modified source with Xcode as documented below; the upstream Releases do **not** contain the direct side-button feature.

The upstream project publishes a universal (Apple Silicon + Intel) `Macrobot-*.zip`, but that binary is not this modified version.

The **upstream** release is ad-hoc signed but **not notarized**, so Gatekeeper may warn on first launch. Custom builds must be signed appropriately before distribution. To open an app you trust:

1. Unzip and move `Macrobot.app` to `/Applications`.
2. Right-click the app → **Open** → **Open** (once), or run
   `xattr -dr com.apple.quarantine /Applications/Macrobot.app`.

## Permissions

Macrobot needs **Accessibility** access to observe and post events — a sandboxed
app can't create a session-level event tap. On first launch it shows a banner;
click it to open **System Settings → Privacy & Security → Accessibility** and
enable Macrobot. The app re-checks every couple of seconds, so the banner clears
as soon as you grant access.

## Default shortcuts

| Action            | Shortcut | Menu             |
| ----------------- | -------- | ---------------- |
| Toggle recording  | **F6**   | ⌘⇧R              |
| Toggle playback   | **F7**   | ⌘⇧P              |
| New macro         | —        | ⌘N               |
| Import macros     | —        | ⌘O               |
| Export selected   | —        | ⌘⇧E              |

The two global shortcuts are configurable in **Settings (⌘,)**. Function keys are
recommended — a shortcut's key can't be captured while you're recording.

## Building from source

Requires Xcode 26.4+ (macOS Tahoe).

```sh
# Open in Xcode and run, or build from the command line:
xcodebuild -project Macrobot.xcodeproj -scheme Macrobot \
  -configuration Debug -destination 'platform=macOS' build
```

The Xcode project uses a file-system-synchronized group, so anything added under
`Macrobot/` is included automatically — no `project.pbxproj` edits needed.

Pushes to `main` build a universal release via GitHub Actions and publish the
zipped app to Releases (see [`.github/workflows/build.yml`](.github/workflows/build.yml)).

## How it works

| Area | File |
| ---- | ---- |
| Recording (listen-only event tap, click coalescing) | [`EventRecorder.swift`](Macrobot/Recording/EventRecorder.swift) |
| Playback (detached loop, speed scaling, drag interpolation) | [`EventPlayer.swift`](Macrobot/Playback/EventPlayer.swift) |
| Global hotkeys (Carbon `RegisterEventHotKey`) | [`Hotkeys/`](Macrobot/Hotkeys/) |
| Model (`Macro`, `MacroEvent`) | [`Models/`](Macrobot/Models/) |
| Storage + import/export | [`MacroStore.swift`](Macrobot/Store/MacroStore.swift) |
