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
./scripts/debug.sh open [module]     # open and pin the notch, optionally on a module (e.g. media)
./scripts/debug.sh close
./scripts/debug.sh activity          # sample banner; also activity-media, activity-timer, clear-activities
./scripts/debug.sh snapshot ~/Desktop/brim-snapshots     # render every state to PNG (sample data)
./scripts/debug.sh selftest ~/Desktop/brim-selftest.txt  # check the real services, write a report
./scripts/debug.sh status ~/Desktop/brim-status.txt      # notch state per display, pointer event rate
./scripts/debug.sh rebuild 30        # rebuild the notch windows, for leak checks
```

### Other scripts

| Script | What it does |
|---|---|
| `scripts/perf.sh [seconds]` | CPU, energy, wakeups and memory for each notch state, as a Markdown table |
| `scripts/switch-peak.sh` | Memory peak while switching modules |
| `scripts/package-beta.sh` | Release build, signature check and zip for testers |

See [docs/PERFORMANCE.md](docs/PERFORMANCE.md), [docs/TESTING.md](docs/TESTING.md) (manual checks and permission audit) and [docs/BETA.md](docs/BETA.md).

## Using the notch

- Hover to peek, keep hovering to open. Click to open and pin.
- ⌘1–9 switches modules (after clicking the notch), as does a two-finger sideways swipe.
- Esc or a click anywhere else closes it.
- Brim steps aside while an app is full screen (Settings can turn this off).
- Settings (menu bar icon → Settings…):
  - opening: hover or click, hover delay, haptics
  - display: which display, hide in full screen
  - modules: order and visibility (hidden modules stop their background work)
  - features: music beside the notch, shelf expiry, clipboard history
  - privacy and feedback: opt-in crash reports, Send Feedback…
  - general: open at login

## Modules

| Module | What it does | Built on | Asks for |
|---|---|---|---|
| Home | Time, weather, next event, now playing | the other modules | — |
| Now Playing | Artwork, scrubber, controls for any app; tints the notch | MediaRemote via `MediaRemoteBridge` | — |
| Calendar | Next 7 days, Join buttons for Zoom/Meet/Teams, tick off reminders | EventKit | Calendars, Reminders |
| Timers | Pomodoro, countdown, stopwatch with laps; live in the notch | UserNotifications | Notifications |
| Clipboard | Searchable history, pinning; skips password managers | NSPasteboard | — |
| Shelf | Drag files onto the notch, drag them out later, AirDrop | bookmarks, Quick Look | — |
| Notes | Scratchpad (optionally shown in the notch) and notes | JSON in Application Support | — |
| System | CPU, memory, network, disk, battery health | Mach, getifaddrs, IOKit | — |
| Weather | Current, 12-hour and 7-day forecast | Open-Meteo, CoreLocation | Location (or pick a city) |
| Revenue | Today's sales and total from Stripe, Polar, Dodo Payments; a banner per sale | REST APIs, read-only keys | A key you paste |
| Analytics | Live visitors, today's traffic, top pages and referrers from DataFast | DataFast API, `df_` key | A key you paste |
| Claude Code | Tokens, replies, tools, streak and 7-day chart; live session status | `~/.claude/projects` logs, a Claude Code hook | Adding the hook (optional) |

Everything is stored in `~/Library/Application Support/Brim`; API keys are in your login Keychain. Brim only talks to Open-Meteo (weather) and the services you connect, with read-only keys.

### Claude Code live status

"Add hook" in the Claude module adds one command per event to `~/.claude/settings.json` (a backup is saved as `settings.json.brim-backup` first). The command pipes Claude Code's event JSON to `~/Library/Application Support/Brim/claude.sock`, a socket only your user can open, and does nothing if Brim isn't running. Each call takes about 15 ms. "Remove hook" takes the entries out again and leaves the rest of the file alone.

### Now Playing and macOS 15.4+

Apple only lets its own processes use the private MediaRemote framework, so Brim runs `/usr/bin/perl` with a tiny library (`MediaRemoteBridge/`) that reads media info and prints it as JSON lines. Same technique as [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), written from scratch. The build script compiles it into `Brim.app/Contents/Frameworks`.

### Permissions during development

The app is signed ad hoc, so macOS may ask for Calendar access, or for Keychain access to saved keys, again after a rebuild. A Developer ID signature (Phase 6) fixes that. Debug builds also carry `get-task-allow` so `leaks`, `sample` and `vmmap` work; release builds don't.

On macOS 26, reading the clipboard in the background needs permission: the Clipboard module asks once, and history only records while macOS is set to always allow Brim.

## Layout

```
Sources/Brim/
├─ App/        BrimApp (menu bar + Settings scenes), AppDelegate, DebugHooks
├─ Notch/      NotchPanel, NotchGeometry, NotchWindowController, ScreenManager
├─ Shell/      NotchShape, NotchViewModel, ShellView (open content, switcher, live activity bar)
├─ Modules/    NotchModule protocol, ModuleRegistry, one folder per module (Service + Module/View)
├─ Services/   ActivityCenter (banners + ongoing activities), Storage, Haptics, Permissions
├─ Design/     Motion (spring presets), Theme, Layout, shared components
└─ Settings/   AppSettings (UserDefaults keys), SettingsView
```

### How the shell works

- One `NotchPanel` per display, sized for the largest state and never resized. It ignores the mouse except while the pointer is over the notch shape, so clicks elsewhere reach the apps underneath.
- `ScreenManager` watches pointer movement with app-wide event monitors (no extra permissions needed) and passes it to each display's `NotchWindowController`, which runs the state machine: closed → peek → open, plus pinned.
- "Activity" is derived: a closed or peeking notch widens its ears whenever `ActivityCenter` has something to show. Banners ("+$49", "Copied") show for a few seconds; ongoing activities (a running timer, music) show while nothing else is.
- Dragging a file towards the notch opens the Shelf; dropping it anywhere on the notch adds it.
- Views that sample (System, Weather) only run while on screen, so a closed notch costs nothing.
- `NotchShape` animates its shoulder and corner radii, so every state change is one spring on one shape.
