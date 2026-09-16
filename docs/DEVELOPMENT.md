# Developing Brim

Brim is a working codename; rename it before launch.

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
./scripts/debug.sh activity          # sample banner; also activity-media, activity-timer,
                                     # activity-claude, activity-download, clear-activities [module]
./scripts/debug.sh celebrate         # confetti (and the sound, if it's on)
./scripts/debug.sh palette           # open the command palette; also ripple
./scripts/debug.sh theme aurora      # midnight, smoke, aurora or custom; also mood working|celebrating|sleeping|idle
./scripts/debug.sh snapshot ~/Desktop/brim-snapshots     # render every state to PNG (sample data)
./scripts/debug.sh effects ~/Desktop/brim-effects        # render the Metal and Core Animation effects to PNG
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

See [PERFORMANCE.md](PERFORMANCE.md), [TESTING.md](TESTING.md) (manual checks and permission audit) and [BETA.md](BETA.md).

## Modules

| Module | Built on | Asks for |
|---|---|---|
| Home | the other modules | — |
| Now Playing | MediaRemote via `MediaRemoteBridge`, Metal | — |
| Calendar | EventKit | Calendars, Reminders |
| Timers | UserNotifications | Notifications |
| Clipboard | NSPasteboard | Paste from other apps (macOS 26) |
| Shelf | bookmarks, Quick Look, an AppKit drag source | — |
| Notes | JSON in Application Support | — |
| System | Mach, getifaddrs, IOKit | — |
| Weather | Open-Meteo, CoreLocation | Location (or pick a city) |
| Revenue | Stripe, Polar and Dodo Payments REST APIs, read-only keys | A key you paste |
| Analytics | DataFast API, `df_` key | A key you paste |
| Claude Code | `~/.claude/projects` logs, a Claude Code hook | Adding the hook (optional) |

Everything is stored in `~/Library/Application Support/Brim`; API keys are in the login Keychain under the service `com.pranava.brim`. Brim only talks to Open-Meteo (weather) and the services you connect, with read-only keys.

## Signature UI

| Feature | How it works | Cost |
|---|---|---|
| Themes | `ThemeStore` holds the palette (background, text, accent, glow, solid or glass). The closed notch always stays black. | — |
| Glass | `.glassEffect()` on macOS 26; an `NSVisualEffectView` blur on 14–15 (`defaults write com.pranava.brim forceBlurFallback -bool YES` to see it on 26) | window server |
| Drop ripple, artwork glow, LED display | Metal shaders compiled at runtime (`Design/Shaders.swift`). The glow and LED display are drawn once and moved by Core Animation; only the one-second ripple draws frame by frame. | ~0.1% while Now Playing is open |
| Live updates beside the notch | Timer ring and Claude pulse are Core Animation layers; revenue ticker; download progress; dots for activities waiting their turn; a volume HUD | 0% (ring 0.4%, the countdown text) |
| Real audio levels | A Core Audio process tap (macOS 14.2+), four bands from an FFT, only while the music bars are showing. Off by default. | 0.17% while the bars show |
| Mascot | Core Animation character with idle, working, celebrating and sleeping moods from `ActivityCenter` | 0% |
| Sale celebration | `CAEmitterLayer` confetti, a double haptic, an optional synthesised "ka-ching" (off by default) | 0% |
| Command palette | `CommandCatalog` builds commands from the modules, timers, music, themes and clipboard; fuzzy matching | — |

The plan called for a Rive mascot and SwiftUI's `.layerEffect`. Rive needs its package and an animation file from the Rive editor, and `.layerEffect` needs a `.metallib` that only Xcode's Metal compiler can build, so both are done without them for now.

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
├─ Shell/      NotchShape, NotchViewModel, ShellView (open content, switcher, live activity bar),
│              EarViews (ring, pulse, ticker), CommandPalette, Celebration
├─ Modules/    NotchModule protocol, ModuleRegistry, one folder per module (Service + Module/View)
├─ Services/   ActivityCenter (HUD, banners, ongoing activities, mood), Storage, Haptics, Permissions,
│              AudioLevels, SystemVolume, DownloadsService, CelebrationSound
├─ Design/     Motion (spring presets), Theme, Palette (themes), Surface (glass), Shaders, Mascot,
│              Layout, shared components
└─ Settings/   AppSettings (UserDefaults keys), SettingsView
```

### How the shell works

- One `NotchPanel` per display, sized for the largest state and never resized. It ignores the mouse except while the pointer is over the notch shape, so clicks elsewhere reach the apps underneath.
- `ScreenManager` watches pointer movement with app-wide event monitors (no extra permissions needed) and passes it to each display's `NotchWindowController`, which runs the state machine: closed → peek → open, plus pinned.
- "Activity" is derived: a closed or peeking notch widens its ears whenever `ActivityCenter` has something to show. A HUD (volume) shows at once; banners ("+$49", "Copied") show one at a time for a few seconds; ongoing activities (a running timer, music) show while nothing else is, highest priority first, with dots for the ones waiting.
- Dragging a file towards the notch opens the Shelf; dropping it anywhere on the notch adds it.
- Views that sample (System, Weather) only run while on screen, so a closed notch costs nothing.
- `NotchShape` animates its shoulder and corner radii, so every state change is one spring on one shape.
