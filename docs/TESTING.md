# Testing

## Automated (debug builds)

```bash
./scripts/build-app.sh debug --run
./scripts/debug.sh selftest ~/Desktop/brim-selftest.txt
./scripts/debug.sh snapshot ~/Desktop/brim-snapshots
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

It records states and counts only, never clipboard contents, notes or track titles.

`snapshot` renders every module and notch state with sample data.

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

### Accessibility

- [ ] Reduce Motion on: the notch fades instead of springing, and the equalizer bars are still.
- [ ] VoiceOver reads the dock buttons, playback controls, reminders and the pin button.

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
| Accessibility, Screen Recording, Input Monitoring | Never | — |

Hidden modules (Settings › Modules) stop their background work: the Now Playing helper exits, the clipboard watcher stops, and Revenue stops checking.
