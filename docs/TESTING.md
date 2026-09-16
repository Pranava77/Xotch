# Testing

## Automated (debug builds)

```bash
./scripts/build-app.sh debug --run
./scripts/debug.sh selftest ~/Desktop/brim-selftest.txt
./scripts/debug.sh snapshot ~/Desktop/brim-snapshots
./scripts/debug.sh effects ~/Desktop/brim-effects
```

The self-test checks:
- **Local services:** system stats, battery health, the Now Playing bridge, and a weather request.
- **Connected services:** the Stripe, Polar, Dodo and DataFast parsers against their documented responses, and that each service rejects a fake key.
- **Keychain and hook:** saving and deleting a Keychain item, and installing then removing the Claude hook in a test settings file.
- **Claude usage:** scan time for the local logs.
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
  - the sale sound, output volume (read only), themes, mascot moods, the timer ring
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

- [ ] Switch between desktops: the notch stays put and doesn't flicker.
- [ ] Make an app full screen (Safari, a video): the notch steps aside within a second and returns when you leave full screen.
- [ ] Split View with two apps: the notch steps aside.
- [ ] Settings › Hide the notch while an app is full screen, turned off: the notch stays over full-screen apps.
- [ ] Stage Manager on: hover, open and drag behave as usual, and the notch doesn't cover the stage strip.

### Sleep, wake and quitting

- [ ] Pin the notch open, sleep the Mac, wake it: the notch comes back closed.
- [ ] A running timer finishes while the Mac is asleep: the "Done" banner and notification appear right after waking.
- [ ] With Revenue connected, a sale made while asleep shows after waking.
- [ ] Log out and back in, or run `pkill Brim`: notes typed just before are saved.

### Permissions (on a fresh macOS user account)

- [ ] Launching and opening Home shows no permission prompts.
- [ ] Each prompt appears only from its own module, as listed in the audit below.
- [ ] Denying each permission shows a clear message in that module with a button to System Settings.

### Signature UI

- [ ] Each theme in Settings › Appearance: the open notch changes at once, the closed notch stays black.
- [ ] Smoke Glass on macOS 26 shows Liquid Glass; on macOS 14–15 (or with `defaults write com.pranava.brim forceBlurFallback -bool YES`) a blur. Text stays readable over a white window and over a dark one.
- [ ] Customise a theme, quit Brim, reopen: the custom colours are kept.
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
- [ ] Settings › Sales › Celebrate: confetti falls from the notch, the trackpad taps twice, and the sound plays only when it's on.
- [ ] Home: the mascot thinks while a timer runs, jumps at a sale, and falls asleep after 10 quiet minutes.
- [ ] Turn on real sound for the music bars: macOS asks to record system audio. Allow it and the bars follow the music; deny it and they bounce as before, and Settings explains how to allow it.
- [ ] Turn on download progress, then download a large file in Safari and in Chrome: the ring and percentage show, then "Done".

### Accessibility

- [ ] Reduce Motion on: the notch fades instead of springing; the equalizer bars, mascot, glow and LED title are still; no confetti or ripple; a flicked shelf item disappears without flying.
- [ ] VoiceOver reads the dock buttons, playback controls, reminders, the pin and ⌘K buttons, the palette rows, the LED title (as plain text) and the mascot's mood. Shelf items offer Open, Show in Finder and Remove actions.

## Permission audit

Every prompt, and what triggers it. Launching Brim triggers none.

| Permission | Asked when | Code |
|---|---|---|
| Calendars and Reminders | Pressing "Allow Calendar and Reminders" in Calendar | `CalendarService.requestAccess` |
| Location | Opening Weather with no city chosen. Home never asks; it only refreshes weather when access is already granted or a city is set | `WeatherService.refresh`, `refreshIfAllowed` |
| Notifications | Starting the first timer | `NotificationPresenter.requestPermissionIfNeeded` |
| Paste from other apps (macOS 26) | Pressing "Allow" in Clipboard. History only reads the clipboard once macOS is set to always allow Brim | `ClipboardService.requestAccess`, `currentAccess` |
| Keychain (saved keys) | Only when a connected service refreshes. Checking whether a key exists never prompts | `KeychainStore.contains` |
| Desktop and Documents folders | Only when the Shelf is shown with files from those folders. At launch, expiry checks dates only | `ShelfService.removeMissing` |
| `~/.claude/settings.json` (not a macOS permission) | Only when you press "Add hook"; a backup is saved first | `ClaudeHookInstaller.install` |
| System audio recording | Only with Settings › "Move the music bars with the real sound" on, the first time the bars show | `AudioTap.start` |
| Downloads folder (may be asked) | Only with Settings › "Show download progress" on | `DownloadsService.settingsChanged` |
| Accessibility, Screen Recording, Input Monitoring | Never | — |

Hidden modules (Settings › Modules) stop their background work: the Now Playing helper exits, the clipboard watcher stops, and Revenue stops checking.
