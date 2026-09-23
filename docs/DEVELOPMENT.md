# Developing Xotch

Xotch is a working codename; rename it before launch.

## Run it

```bash
./scripts/build-app.sh debug --run
```

This builds `build/Xotch.app` with Swift Package Manager, signs it ad hoc and opens it. Xotch lives in the menu bar (no Dock icon). Quit it from the menu bar icon.

Needs macOS 14 or later. Xcode isn't required: without it, the script builds against the macOS 26 SDK from Command Line Tools, because the macOS 27 SDK's SwiftUI `@State` macro needs a compiler plugin that only ships with Xcode. With Xcode installed, `swift build` and the script use its toolchain instead, and you can open `Package.swift` in it.

### Debug commands

With a debug build running:

```bash
./scripts/debug.sh open [module]     # open and pin the notch, optionally on a module (e.g. media)
./scripts/debug.sh close
./scripts/debug.sh activity          # sample banner; also activity-media, activity-timer,
                                     # activity-claude, activity-download, activity-recording,
                                     # clear-activities [module]
./scripts/debug.sh capture area      # take a screenshot: area, window or screen (needs permission)
./scripts/debug.sh trace-spaces ~/Desktop/spaces.txt  # log desktop-switch notifications with timestamps
./scripts/debug.sh record screen     # start recording: screen, window or area; record-stop ends it
./scripts/debug.sh celebrate         # confetti (and the sound, if it's on)
./scripts/debug.sh palette           # open the command palette; also ripple
./scripts/debug.sh theme aurora      # midnight, smoke, aurora or custom; also mood working|celebrating|sleeping|idle
./scripts/debug.sh snapshot ~/Desktop/xotch-snapshots     # render every state to PNG (sample data)
./scripts/debug.sh effects ~/Desktop/xotch-effects        # render the Metal and Core Animation effects to PNG
./scripts/debug.sh marketing /tmp/xotch-images            # regenerate the README's product images (sample data)
./scripts/debug.sh selftest ~/Desktop/xotch-selftest.txt  # check the real services, write a report
./scripts/debug.sh status ~/Desktop/xotch-status.txt      # notch state per display, pointer event rate
./scripts/debug.sh rebuild 30        # rebuild the notch windows, for leak checks
./scripts/debug.sh click life.newArc # click a control by name, or by "x,y" in window coordinates
./scripts/debug.sh type "Ship it"    # type into whatever has focus; \n is Return
./scripts/debug.sh probe ~/Desktop/xotch-probe.txt  # hit-test a grid down the open notch
```

### Clicking the notch yourself

`click` and `type` synthesise real events and post them to the app's own event
queue, so a debug build can drive its own UI with no Accessibility permission
and no robot moving your cursor. Controls tagged with `.debugFrame("life.newArc")`
can be clicked by name, which survives layout changes; coordinates are a
fallback, in window points from the bottom left.

Two things to know:

- The order is: **queue a mouse-up, send the mouse-down, send a mouse-up.** Each
  part earns its place. A text view's `mouseDown` sits in
  `nextEventMatchingMask` until the mouse comes back up and only reads the
  queue, so without the queued up the app hangs there eating keystrokes.
  `NSApp.postEvent` alone doesn't work either: the window server maps the
  location through the window's own geometry and the click lands somewhere else
  (measured: about 0.9× the panel, so a button at the top right was missed by
  50pt). And a button whose up arrives anywhere but on it reads the press as
  dragged off and does nothing, which is why the sent up matters.
- `.debugFrame(_:)` ignores anything laid out in `snapshotMode`. Snapshots and
  marketing shots build the whole shell inside an `ImageRenderer`, off screen
  and in its own coordinate space; recording those frames pointed every later
  click at a window that wasn't there.
- `selftest` runs a UI pass (`life ui: … → PASS`) that clicks Life's tabs, makes
  an arc, saves it, opens another and cancels. That pass exists because of the
  two bugs below.

The project lives on the Desktop, which macOS protects, and every rebuild resets the debug build's permissions. So render product images into a folder outside Desktop, Documents and Downloads, then copy them into `docs/images`. Writing there directly makes Xotch wait for the "access files in your Desktop folder" prompt.

### Other scripts

| Script | What it does |
|---|---|
| `scripts/perf.sh [seconds]` | CPU, energy, wakeups and memory for each notch state, as a Markdown table |
| `scripts/switch-peak.sh` | Memory peak while switching modules |
| `scripts/package-beta.sh` | Release build, signature check and zip for testers |
| `scripts/package-dmg.sh` | Release build wrapped in a drag-to-Applications disk image (uses `create-dmg` if installed, `hdiutil` otherwise) |

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
| Capture | `/usr/sbin/screencapture`, ScreenCaptureKit, Spotlight (`NSMetadataQuery`) | Screen Recording; Microphone (optional) |
| Life | JSON in Application Support, UserNotifications | Notifications (only when you set a habit reminder) |
| Notes | JSON in Application Support | — |
| System | Mach, getifaddrs, IOKit | — |
| Claude Code | `~/.claude/projects` logs, a Claude Code hook | Adding the hook (optional) |

Everything is stored in `~/Library/Application Support/Xotch`. Xotch makes no network requests.

The Revenue, Analytics and Weather modules were removed. On first launch after that change, `Services/LegacyCleanup.swift` deletes what they left behind: their Keychain items, cached files and settings, and their IDs in the saved module order.

## Signature UI

| Feature | How it works | Cost |
|---|---|---|
| Themes | `ThemeStore` holds the palette (background, text, accent, glow, solid or glass). The closed notch always stays black. | — |
| Glass | `.glassEffect()` on macOS 26; an `NSVisualEffectView` blur on 14–15 (`defaults write com.pranava.xotch forceBlurFallback -bool YES` to see it on 26) | window server |
| Drop ripple, artwork glow, LED display | Metal shaders compiled at runtime (`Design/Shaders.swift`). The glow and LED display are drawn once and moved by Core Animation; only the one-second ripple draws frame by frame. | ~0.1% while Now Playing is open |
| Live updates beside the notch | Timer ring and Claude pulse are Core Animation layers; a rolling ticker (`ActivityContent.ticker`); download progress; dots for activities waiting their turn; a volume HUD | 0% (ring 0.4%, the countdown text) |
| Real audio levels | A Core Audio process tap (macOS 14.2+), four bands from an FFT, only while the music bars are showing. Off by default. | 0.17% while the bars show |
| Mascot | Core Animation character with idle, working, celebrating and sleeping moods from `ActivityCenter` | 0% |
| Celebration | `CAEmitterLayer` confetti and a double haptic when a focus session finishes (Settings › Features) | 0% |
| Screen recording | `SCStream` with an `SCRecordingOutput` writes the movie itself (macOS 15+). Xotch's own windows are filtered out, so the notch never appears in a recording. | measured below |
| Command palette | `CommandCatalog` builds commands from the modules, timers, music, themes and clipboard; fuzzy matching | — |

The plan called for a Rive mascot and SwiftUI's `.layerEffect`. Rive needs its package and an animation file from the Rive editor, and `.layerEffect` needs a `.metallib` that only Xcode's Metal compiler can build, so both are done without them for now.

### Capture

`Modules/Capture` has three parts:

- **Screenshots** run macOS's own `/usr/sbin/screencapture`, so the crosshair, the window picker and Esc behave exactly as they do with ⌘⇧4. Xotch closes the notch and waits 250 ms first, so it isn't in the shot.
- **Recordings** use ScreenCaptureKit. A window is chosen with `SCContentSharingPicker` (macOS's own picker, which needs no permission); an area with `RegionPicker`, a dimmed overlay panel per display whose selection becomes `SCStreamConfiguration.sourceRect`. `RecordingFrame` draws a dashed border around that area while it records.
- **The shelf** lists Xotch's folder (scanned with `FileManager`) and, when the setting is on, macOS's own screenshots, found with a live `NSMetadataQuery` for `kMDItemIsScreenCapture`. That query only runs while the Capture module is on screen, because the folder macOS saves to is usually Desktop, and reading it can ask for Desktop access.

Captures are saved to `~/Pictures/Xotch` by default. Pictures is one of the few home folders macOS doesn't protect, so saving there asks for nothing. Removing an item from the shelf only hides it (the paths are kept in `capture-hidden.json`); the file itself stays until you move it to the Trash.

### Life

`Modules/Life` holds to-dos, arcs and the commit graph in one `life.json`, saved through `Storage` like Notes.

- **Scoring:** a finished to-do is worth 1, a habit check-in 2, a milestone 5 (`LifeScore`). Day totals are cached in `LifeService` and thrown away whenever something changes, so the graph never recomputes a year of history while you type.
- **Routine is a timetable:** hours down the left, the seven days across, and the fixed weekly slots in between (`TimetableEntry`: a weekday, minutes after midnight, a length — no date, because it is the same every week). `TimetableMetrics` owns the minutes-to-points maths and widens the usual 07:00–23:00 to hold anything outside it; `TimetableGrid.swift` holds the ruler, the hour lines and the blocks. Blocks are ordinary views positioned with `.offset`, not a `Canvas` like `LifeGraph`, because they need context menus and clicks. Only the routine is drawn there: to-dos live on Today, and the tab shows weekday names rather than dates, since the week it describes is every week.
- **A time is only a time when it says so:** `LifeTime.parse` reads "9:30 Maths", "14:00-15:30 Lab" and "2pm dentist", but a bare number is never a time — "30 push-ups" would be a slot at half past midnight otherwise. It needs two digits after a colon or a dot, or an am/pm. Times are `Int` minutes after midnight, matching `Habit.reminder`; nothing in Life stores a wall-clock `Date`.
- **Typing builds the routine:** each day carries an add field (`DayAddField`) that writes a weekly slot through `addSlot(_:weekday:)`, "#arc" filing included, and keeps focus so a day can be listed out in one go. The fields stay quiet — no fill, dimmed plus, "Add" rather than the example — until hovered or focused, because seven lit fields would shout over the week. A slot is reference only: never ticked, never a commit, so the graph keeps meaning what it meant.
- **The graph** is a single SwiftUI `Canvas`: 53 columns × 7 days drawn in one pass, with hit-testing worked out from the point rather than a view per square.
- **Reminders** (`LifeReminders`) are repeating `UNCalendarNotificationTrigger`s with stable identifiers, so rescheduling replaces them instead of piling up. `plans(arcs:eveningNudge:)` is pure, which is what the self-test checks. The notification carries a **Check in** button, handled without opening the notch.
- **Clicks in the designer, twice broken:** the arc designer painted its own card with `.overlay(RoundedRectangle(…).fill(Theme.fill))`. A filled SwiftUI shape takes hit tests even at 7% opacity, so the overlay sat on top of the designer and ate every click in it — the tabs above still worked, which made it look like only "the arc" was broken. It's a `.background` now, and decorative strokes elsewhere carry `.allowsHitTesting(false)`. With clicks restored, saving an arc then killed the app outright: the designer was handed `Binding($life.draft)`, and that force-unwrapping binding traps when SwiftUI updates the subtree once more after the draft is cleared (`BindingOperations.ForceUnwrapping.get` in the crash report). `LifeService.draftBinding` falls back to a placeholder for that last update instead. Both are covered by the self-test's UI pass.
- **A wider notch:** `NotchModule.openSize` lets a module ask for more room; Life asks for `Layout.wideOpenSize` (1120×580) and everything else keeps 600×300. The panel is sized once from `Layout.maxOpenSize` (so 1236×624 including shoulders and the shadow margin) and never resized, and `NotchViewModel.openSize` clamps to the screen so a small display still fits.
- **The graph fills the room it has:** `LifeGraph.cell(fitting:columns:)` picks the biggest square between 9 and 14pt that fits a year of weeks in the width available, and `LifeGraph.height(cell:)` gives the row exactly that height — the old fixed 100pt box shaved the bottom row. The day panel's width is reserved whether or not a day is selected, so clicking a square slides the panel in without reflowing the year underneath it.

### Claude Code live status

"Add hook" in the Claude module adds one command per event to `~/.claude/settings.json` (a backup is saved as `settings.json.xotch-backup` first). The command pipes Claude Code's event JSON to `~/Library/Application Support/Xotch/claude.sock`, a socket only your user can open, and does nothing if Xotch isn't running. Each call takes about 15 ms. "Remove hook" takes the entries out again and leaves the rest of the file alone.

### Now Playing and macOS 15.4+

Apple only lets its own processes use the private MediaRemote framework, so Xotch runs `/usr/bin/perl` with a tiny library (`MediaRemoteBridge/`) that reads media info and prints it as JSON lines. Same technique as [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), written from scratch. The build script compiles it into `Xotch.app/Contents/Frameworks`.

### The landing page

`docs/index.html` is the product page: one self-contained file that reuses the rendered images in `docs/images`, so there's no build step. Preview it by opening the file; to publish it with GitHub Pages, set Pages to the `main` branch's `/docs` folder — which needs the repository to be public, or a paid plan while it's private. `docs/.nojekyll` keeps GitHub from running Jekyll over it. The beta button is a `mailto:` placeholder; swap in your address or a form service before you share the link.

### Known: the notch slides when you change desktop

macOS animates every window sideways during a desktop switch, and the notch goes with them. It shouldn't: the panel is set up exactly as Apple documents for a window that stays put — `canJoinAllSpaces`, `stationary`, `fullScreenAuxiliary`, `auxiliary`, `canJoinAllApplications`, above the menu bar — and `scripts/debug.sh status` prints those flags back at runtime to prove they're still applied.

What was measured, with a window-server trace (`CGWindowListCopyWindowInfo` on Xotch's own window, 30 times a second) against Xotch's own notification log:

- The panel's reported position slides from x 542 to about −1300 or +2400 and back, for one to six seconds, while Xotch's own `panel.frame` never changes. The window server is moving it, not Xotch.
- A test harness of panels at six different levels (menu bar + 3, `.screenSaver`, `.popUpMenu`, assistive, cursor, plain floating) with several collection behaviours **all slid by exactly the same amount**. No level or behaviour escapes it.
- It happens with Stage Manager both on and off.
- `NSWorkspace.activeSpaceDidChangeNotification` arrives about **3.4 seconds after the slide starts**, and for three of five switches never arrived at all, so it can't be used to get out of the way in time.
- Hiding the window once the slide is detected doesn't help either: macOS composites a snapshot of each window taken before the animation begins, so changing `alphaValue` mid-slide changes nothing on screen. That attempt was written, measured and removed; only the DEBUG tracing is kept (`scripts/debug.sh trace-spaces <file>`).

The one thing that removes it is System Settings › Accessibility › Display › **Reduce motion**, which turns the desktop-switch animation off entirely.

Worth revisiting if a future macOS adds a real opt-out, or if the closed notch is ever drawn by something that isn't a window.

### Updating from a build called Brim

Xotch was called Brim until the name was chosen. `Services/Migration.swift` runs once, before anything reads `Storage` or the settings, and moves everything across: the Application Support folder (notes, to-dos, arcs, clipboard, shelf), the settings from the old `com.pranava.brim` domain, and an installed Claude Code hook, which pointed at the old socket path.

### Permissions during development

The app is signed ad hoc, so macOS may ask for Calendar access again after a rebuild. Screen Recording is worse: macOS ties the approval to the exact signature, so a rebuilt app is silently denied and never asks again. Clear it and ask afresh with:

```bash
tccutil reset ScreenCapture com.pranava.xotch
```

Then relaunch and take a capture. Grant it on the build you mean to test, and don't rebuild until you're done. A Developer ID signature (Phase 6) fixes that. Debug builds also carry `get-task-allow` so `leaks`, `sample` and `vmmap` work; release builds don't.

On macOS 26, reading the clipboard in the background needs permission: the Clipboard module asks once, and history only records while macOS is set to always allow Xotch.

## Layout

```
Sources/Xotch/
├─ App/        XotchApp (menu bar + Settings scenes), AppDelegate, DebugHooks, MarketingShots
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
- Views that sample (System) only run while on screen, so a closed notch costs nothing.
- `NotchShape` animates its shoulder and corner radii, so every state change is one spring on one shape.
