# Testing

## Automated (debug builds)

```bash
./scripts/build-app.sh debug --run
./scripts/debug.sh selftest ~/Desktop/xotch-selftest.txt
./scripts/debug.sh snapshot ~/Desktop/xotch-snapshots
./scripts/debug.sh effects ~/Desktop/xotch-effects
```

The self-test checks:
- **Local services:** system stats, battery health and the Now Playing bridge.
- **Claude hook:** installing then removing the Claude hook in a test settings file.
- **Claude usage:** scan time for the local logs.
- **Life:** the weighted score and its five levels, the week's start day, sample streaks and the graph's 53×7 days, arc progress, and the reminder schedule a set of habits produces (including that it's stable when worked out twice). It counts only; no task titles are read.
- **Capture:** file naming (including the " (2)" suffix), the Spotlight predicate for macOS screenshots, both capture folders, the `screencapture` display number, and the area picker's maths (including a too-small drag and one that runs off the screen). It never takes a capture.
- **Phase 5 logic:**
  - full-screen detection (7 window layouts) and screen-coordinate conversion
  - CPU counter wrap-around
  - clock formatting with extreme values
  - crash-report detection
- **Phase 4 logic:**
  - command palette: duration parsing ("10m", "90s", "1h"), fuzzy matching, results for sample queries
  - swipe stretch at the first and last module
  - the dot-matrix font, printed as text
  - Metal shaders compile, and how long it took
  - the audio analyser against 80 Hz, 2.5 kHz and 7 kHz tones and silence
  - output volume (read only), themes, mascot moods, the timer ring
  - that the cleanup for the removed Revenue, Analytics and Weather modules has run, and strips their IDs from the module order
  - download progress, using a fake download in a scratch folder

It records states and counts only, never clipboard contents, notes or track titles. The palette checks run on sample data, because the palette searches the clipboard.

`snapshot` renders every module and notch state with sample data, each theme, the palette, the swipe stretch, the mascot's moods and each kind of live activity. Your own live activities are set aside while it runs.

`effects` draws the Metal effects (ripple, glow, LED display) and the Core Animation pieces (mascot, ring, glow and LED views) to PNGs. Snapshots can't show these, because ImageRenderer doesn't draw Metal or AppKit views.

## Manual checks

These need hardware or situations a script can't create. Tick them before a beta build goes out.

### Displays

- [ ] External display connected, Settings › Show the notch on › Automatic: the notch stays on the built-in display.
- [ ] Same, with "All displays": the external display gets a drawn notch the height of its menu bar, and hover, open and drag work there.
- [ ] Pick the external display by name: only it has a notch.
- [ ] Unplug the external display while its notch is open: no crash; the built-in notch keeps its state.
- [ ] Change the built-in display's resolution (More Space / Larger Text): the notch resizes to the new menu bar height.
- [ ] Lid closed with an external display (clamshell): the external display gets the notch; opening the lid moves it back.

### Spaces, full screen and Stage Manager

- [ ] Switch between desktops: the notch comes back in place afterwards. It slides across with the animation on the way — that's macOS moving every window, and no window can opt out; see DEVELOPMENT.md. With Reduce Motion on, there's no animation and no slide.
- [ ] Make an app full screen (Safari, a video): the notch steps aside within a second and returns when you leave full screen.
- [ ] Split View with two apps: the notch steps aside.
- [ ] Settings › Hide the notch while an app is full screen, turned off: the notch stays over full-screen apps.
- [ ] Stage Manager on: hover, open and drag behave as usual, and the notch doesn't cover the stage strip.

### Sleep, wake and quitting

- [ ] Pin the notch open, sleep the Mac, wake it: the notch comes back closed.
- [ ] A running timer finishes while the Mac is asleep: the "Done" banner and notification appear right after waking.
- [ ] Log out and back in, or run `pkill Xotch`: notes typed just before are saved.

### Permissions (on a fresh macOS user account)

- [ ] Launching and opening Home shows no permission prompts.
- [ ] Each prompt appears only from its own module, as listed in the audit below.
- [ ] Denying each permission shows a clear message in that module with a button to System Settings.

### Signature UI

- [ ] Each theme in Settings › Appearance: the open notch changes at once, the closed notch stays black.
- [ ] Smoke Glass on macOS 26 shows Liquid Glass; on macOS 14–15 (or with `defaults write com.pranava.xotch forceBlurFallback -bool YES`) a blur. Text stays readable over a white window and over a dark one.
- [ ] Customise a theme, quit Xotch, reopen: the custom colours are kept.
- [ ] Drop a file on the notch: a ripple spreads from where it landed.
- [ ] Now Playing: the title scrolls on the dot-matrix display a column at a time; the artwork glows in its colours and the glow shifts while music plays.
- [ ] Shelf: flick a file upwards and it flies off; a short or slow pull springs back. Dragging the same file down to the desktop still copies it. Double-click opens, Option-click removes, right-click shows the menu.
- [ ] On the open notch, swipe past the last module: the content stretches and springs back with one haptic tick.
- [ ] On the closed notch, scroll with a trackpad and with a mouse wheel: the volume changes, the bar shows beside the notch, and the notch doesn't open while you scroll. With an output that has no volume control (some HDMI), the notch says "Fixed".
- [ ] ⌘K: type "cal" and press Return; type "7 min" and press Return; ↑ and ↓ move the selection; Esc closes only the palette; a second Esc closes the notch.
- [ ] Type part of something you copied: "Copy …" appears and copies it.
- [ ] Start a timer: the ring around the icon fills over the whole timer; pause it and the ring stops.
- [ ] Claude Code working: a soft pulse behind the sparkle; waiting for you: a faster pulse.
- [ ] Music and a timer at once: the timer shows, with one dot for the music waiting.
- [ ] Settings › Features › Celebrate: confetti falls from the notch and the trackpad taps twice. A finished focus session does the same, unless "Celebrate finished focus sessions" is off.
- [ ] Home: the mascot thinks while a timer runs, jumps when a focus session finishes, and falls asleep after 10 quiet minutes.
- [ ] Updating from a build that had Revenue, Analytics or Weather: those modules are gone from the dock and Settings, and Keychain Access has no `com.pranava.xotch` items for them.
- [ ] Life › Routine: type "9:30 Maths" into Monday and "14:00-15:30 Lab" into Tuesday. Both land at the right hour for the right length, and are still there after a relaunch and in any week.
- [ ] Life › Routine: "30 push-ups" is refused rather than becoming a slot at half past midnight; "9:30 Lab #arc" takes the arc's colour.
- [ ] Life › Routine: right-click a slot to move it to another day or remove it. Today's column is marked, and the line across it sits at the current time.
- [ ] Life › Today: right-click a to-do and move it to another day; it lands there and stays after a relaunch.
- [ ] Life › Today: type a to-do and press Return; tick it off and watch today's square darken and the streak rise.
- [ ] Type `#ship` at the end of a to-do: it lands on the arc whose name starts with that.
- [ ] Life › Arcs › New arc: name it, pick a colour and an end date, add a habit and a milestone, press Lock it in. Quit Xotch, reopen: it's all still there.
- [ ] Check in on a habit, then finish a milestone: confetti falls and the mascot cheers.
- [ ] Set a habit reminder a minute ahead: macOS asks for notifications the first time, the reminder arrives, and **Check in** on it ticks the habit off without opening the notch.
- [ ] Two displays: both show a notch, the one without hardware gets a drawn pill in its menu bar sized to that screen, and `scripts/debug.sh status` lists both. Unplug and replug the second display, then move the menu bar between displays in System Settings: both come back correctly sized.
- [ ] Life on a display without a notch: the open header has no empty gap where the camera housing would be.
- [ ] Leave an unfinished to-do overnight: the next morning it's on today, with "1 carried over" beside the notch.
- [ ] Click an old square in the graph: it lists what you finished that day, and the × goes back to today.
- [ ] Switching to Life grows the notch and switching away shrinks it, with no flicker in other modules.
- [ ] Capture › Screenshot › Area: the crosshair appears without the notch in the shot, the file lands on the shelf, and a preview shows beside the notch. Esc during the crosshair leaves no file.
- [ ] Screenshot › Window, and Screen: same, and the picture matches what you chose. With "Copy to clipboard" on, ⌘V pastes the image.
- [ ] Take a screenshot with ⌘⇧4: it appears on the Capture shelf within a second or two (macOS may ask for access to your Desktop folder the first time).
- [ ] Record › Screen for 5 seconds: a red timer shows beside the notch and in the open notch, clicking either stops it, and the movie plays with sound.
- [ ] Record › Area: the dashed frame stays around the area, and the recording contains only that area, without Xotch's frame or notch.
- [ ] Record › Window: macOS's window picker appears; the recording follows that window.
- [ ] While recording, turn on Microphone in Capture: the next recording asks for microphone access, and denying it records without the microphone and says so.
- [ ] A capture tile: double-click opens it, right-click offers Quick Look, Copy, Show in Finder, AirDrop, Add to Shelf and Move to Trash, and flicking it up takes it off the shelf without deleting the file.
- [ ] On macOS 14: the Record buttons are greyed out and say recording needs macOS 15.
- [ ] Turn on real sound for the music bars: macOS asks to record system audio. Allow it and the bars follow the music; deny it and they bounce as before, and Settings explains how to allow it.
- [ ] Turn on download progress, then download a large file in Safari and in Chrome: the ring and percentage show, then "Done".

### Accessibility

- [ ] Reduce Motion on: the notch fades instead of springing; the equalizer bars, mascot, glow and LED title are still; no confetti or ripple; a flicked shelf item disappears without flying.
- [ ] Reduce Motion with a capture: flicking a tile off the shelf removes it without the throw.
- [ ] VoiceOver reads the dock buttons, playback controls, reminders, the pin and ⌘K buttons, the palette rows, the LED title (as plain text) and the mascot's mood. Shelf items offer Open, Show in Finder and Remove actions.

## Permission audit

Every prompt, and what triggers it. Launching Xotch triggers none.

| Permission | Asked when | Code |
|---|---|---|
| Calendars and Reminders | Pressing "Allow Calendar and Reminders" in Calendar | `CalendarService.requestAccess` |
| Notifications | Starting the first timer | `NotificationPresenter.requestPermissionIfNeeded` |
| Paste from other apps (macOS 26) | Pressing "Allow" in Clipboard. History only reads the clipboard once macOS is set to always allow Xotch | `ClipboardService.requestAccess`, `currentAccess` |
| Desktop and Documents folders | Only when the Shelf is shown with files from those folders. At launch, expiry checks dates only | `ShelfService.removeMissing` |
| `~/.claude/settings.json` (not a macOS permission) | Only when you press "Add hook"; a backup is saved first | `ClaudeHookInstaller.install` |
| System audio recording | Only with Settings › "Move the music bars with the real sound" on, the first time the bars show | `AudioTap.start` |
| Notifications (Life) | Only when you set a habit reminder or the evening nudge | `LifeReminders.requestPermission` |
| Screen Recording | The first screenshot or recording. Choosing a window to record uses macOS's picker instead, which asks for nothing | `CaptureService.ensureScreenPermission` |
| Microphone | Only when a recording starts with Capture › Microphone on | `CaptureService.microphoneAllowed` |
| The folder macOS saves screenshots in (usually Desktop) | Only when the Capture module is open with "List screenshots taken with ⌘⇧3…" on | `CaptureService.startQuery` |
| Downloads folder (may be asked) | Only with Settings › "Show download progress" on | `DownloadsService.settingsChanged` |
| Accessibility, Input Monitoring | Never | — |

Hidden modules (Settings › Modules) stop their background work: the Now Playing helper exits and the clipboard watcher stops.
