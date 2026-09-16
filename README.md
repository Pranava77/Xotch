# Brim

A MacBook notch app. Working codename; rename before launch.

## Run it

```bash
./scripts/build-app.sh debug --run
```

This builds `build/Brim.app` with Swift Package Manager, signs it ad hoc and opens it. Brim lives in the menu bar (no Dock icon). Quit it from the menu bar icon.

Needs macOS 14 or later. Xcode isn't required yet: without Xcode, the script builds against the macOS 26 SDK from Command Line Tools, because the macOS 27 SDK's SwiftUI `@State` macro needs a compiler plugin that only ships with Xcode. Once Xcode is installed, open `Package.swift` in it.

### Debug commands

With a debug build running:

```bash
./scripts/debug.sh open        # open and pin the notch
./scripts/debug.sh close
./scripts/debug.sh activity    # show a sample live activity
./scripts/debug.sh snapshot ~/Desktop/brim-snapshots   # render every state to PNG
```

## Using the notch

- Hover to peek, keep hovering to open. Click to open and pin.
- ⌘1–9 switches modules (after clicking the notch), as does a two-finger sideways swipe.
- Esc or a click anywhere else closes it.
- Settings (menu bar icon → Settings…): hover or click to open, hover delay, haptics, which display, module order and visibility, open at login.

## Layout

```
Sources/Brim/
├─ App/        BrimApp (menu bar + Settings scenes), AppDelegate, DebugHooks
├─ Notch/      NotchPanel, NotchGeometry, NotchWindowController, ScreenManager
├─ Shell/      NotchShape, NotchViewModel, ShellView (open content, switcher, live activity bar)
├─ Modules/    NotchModule protocol, ModuleRegistry, Phase 1 placeholder modules
├─ Services/   ActivityCenter, Haptics
├─ Design/     Motion (spring presets), Theme and Layout
└─ Settings/   AppSettings (UserDefaults keys), SettingsView
```

### How the shell works

- One `NotchPanel` per display, sized for the largest state and never resized. It ignores the mouse except while the pointer is over the notch shape, so clicks elsewhere reach the apps underneath.
- `ScreenManager` watches pointer movement with app-wide event monitors (no extra permissions needed) and passes it to each display's `NotchWindowController`, which runs the state machine: closed → peek → open, plus pinned.
- "Activity" is derived: a closed or peeking notch widens its ears whenever `ActivityCenter` has something to show.
- `NotchShape` animates its shoulder and corner radii, so every state change is one spring on one shape.
