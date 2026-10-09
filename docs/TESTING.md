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
- **To-dos:** adding, ticking, moving to someday and deleting a to-do, then cleaning up. It only touches its own test to-do; no titles are read.
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
  - output volume (read only), the timer ring
  - **Retro sounds:** all nine cues render, are audible, stay under the clip limit and start and end at silence, so none clicks. Nothing plays and the audio engine stays off while the setting is off.
  - that the cleanup for the removed Revenue, Analytics and Weather modules has run, and strips their IDs from the module order
  - download progress, using a fake download in a scratch folder

It records states and counts only, never clipboard contents, notes or track titles. The palette checks run on sample data, because the palette searches the clipboard.

`snapshot` renders every module and notch state with sample data, the palette, the swipe stretch and each kind of live activity. Your own live activities are set aside while it runs.

`effects` draws the Metal effects (ripple, glow, LED display) and the Core Animation pieces (ring, glow and LED views) to PNGs. Snapshots can't show these, because ImageRenderer doesn't draw Metal or AppKit views.

## Manual checks

These need hardware or situations a script can't create. Tick them before a beta build goes out.

### Welcome

- [ ] First launch (`defaults delete com.pranava.xotch welcomeSeen`): about a second in, the notch opens and "hello" writes itself, traced then filled, then hola, bonjour and on; Continue arrives after the first word. Continue shows three things to know; Set Up AI… and Set Up Dictation… open those Settings pages; Start Using Xotch closes it and it doesn't come back at the next launch. Esc or a click elsewhere also counts as seen.
- [ ] Menu bar › Welcome to Xotch… shows it again. Reduce Motion shows "hello" already written.

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

- [ ] The open notch is macOS's dark material (a hint of the desktop shows through); the closed notch stays black. Text stays readable over a light wallpaper.
- [ ] Home's Mirror tile reads "Click to look" and the camera light is off. Click: macOS asks for the camera once, then you appear, flipped like a mirror. Click again, switch tabs, or close the notch: the camera light goes off (`debug.sh status` › `mirror: … running=false`).
- [ ] Camera denied: the tile says so, and a click opens Privacy & Security › Camera.
- [ ] Settings › Arcade sound effects is off by default and nothing plays. Turn it on: a coin blip plays. Open and close the notch, switch modules, add, tick and delete a to-do, pin, and finish a 1-minute timer: each has its own sound and nothing clips or clicks. The volume slider changes the level. Turn it off: silence.
- [ ] Settings › Show volume and brightness in the notch (off by default; needs a real keyboard, which the debug tools can't press). Turn it on: macOS asks for Accessibility. Grant it in System Settings; within a couple of seconds the row in Settings disappears and the keys work. Press volume up and down: the bar shows beside the closed notch (in the header if it's open), macOS's own popup does not, and the level matches the menu bar's. Mute shows an empty bar. Shift+Option gives smaller steps; Option alone still opens Sound settings. Brightness up and down move the built-in display and show the bar.
- [ ] Media keys, when Xotch can't act: play a full-screen app so the notch is hidden (the keys should give macOS's popup); pick an HDMI or other output with no volume control; use an external monitor's brightness keys. In each, macOS handles the key as normal. Quit Xotch: the keys work as normal.
- [ ] Turn the media-key setting off, or revoke Accessibility: the keys go back to macOS at once, with no relaunch.
- [ ] Buttons are Liquid Glass on macOS 26; on macOS 14–15 (or with `defaults write com.pranava.xotch forceBlurFallback -bool YES`) flat fills. Text stays readable.
- [ ] Drop a file on the notch: a ripple spreads from where it landed.
- [ ] Now Playing: the title scrolls on the dot-matrix display a column at a time; the artwork glows in its colours and the glow shifts while music plays.
- [ ] Shelf: flick a file upwards and it flies off; a short or slow pull springs back. Dragging the same file down to the desktop still copies it. Double-click opens, Option-click removes, right-click shows the menu.
- [ ] On the open notch, swipe past the last module: the content stretches and springs back with one haptic tick.
- [ ] On the closed notch, scroll with a trackpad and with a mouse wheel: the volume changes, the bar shows beside the notch, and the notch doesn't open while you scroll. With an output that has no volume control (some HDMI), the notch says "Fixed".
- [ ] ⌘K: type "cal" and press Return; type "7 min" and press Return; ↑ and ↓ move the selection; Esc closes only the palette; a second Esc closes the notch.
- [ ] Type part of something you copied: "Copy …" appears and copies it.
- [ ] Start a timer: the ring around the icon fills over the whole timer; pause it and the ring stops.
- [ ] Claude Code working: a soft pulse behind the sparkle; waiting for you: a faster pulse.
- [ ] Music and a timer at once: they take turns every 6 s, the notch keeps one width, and two dots show which is up. Clicking the right ear skips to the next without opening the notch.
- [ ] A screen recording, or Claude waiting for you (fast pulse), stays in the ear while other things are live.
- [ ] Settings › Features › Celebrate: confetti falls from the notch and the trackpad taps twice. A finished focus session does the same, unless "Celebrate finished focus sessions" is off.
- [ ] Closed notch: the mascot sits at the outer edge of the left ear; a live activity's icon moves to the right ear beside its status, and Settings › Appearance › Companion › Nothing hides it.
- [ ] Updating from a build that had Adiyogi in the ear (or never chose a companion): the mascot is there instead, and the Companion picker shows Mascot, not a blank.
- [ ] Updating from a build that had Revenue, Analytics or Weather: those modules are gone from the header tabs, the more grid and Settings, and Keychain Access has no `com.pranava.xotch` items for them.
- [ ] To-dos: right-click a to-do and move it to tomorrow or someday; it lands there and stays after a relaunch.
- [ ] To-dos: type a to-do and press Return; tick it off and it strikes through.
- [ ] Two displays: both show a notch, the one without hardware gets a drawn pill in its menu bar sized to that screen, and `scripts/debug.sh status` lists both. Unplug and replug the second display, then move the menu bar between displays in System Settings: both come back correctly sized.
- [ ] To-dos on a display without a notch: the open header has no empty gap where the camera housing would be.
- [ ] Leave an unfinished to-do overnight: the next morning it's on today, with "1 carried over" beside the notch.
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

### Dictation

Needs Apple silicon and macOS 26. `debug.sh dictation-download`, `dictation-feed <wav>`, `dictate-file <wav>` and `status` help.

- [ ] Settings › Dictation: Download Whistle shows progress, then "Whistle, ready"; Remove deletes it.
- [ ] Hold Fn in TextEdit, say a sentence, let go: the text appears at the cursor, tidied, and a short "inserted" banner shows. The clipboard still holds what it held before.
- [ ] While holding Fn: a red microphone and a moving waveform beside the notch; the Dictation page shows the words as they're heard.
- [ ] Double-tap Fn: it keeps listening after you let go; press Fn again to insert.
- [ ] Fn+→ while talking, or Esc: nothing is inserted.
- [ ] A quick tap of Fn alone: nothing happens.
- [ ] Click into a password field and hold Fn: "Not into a password field", nothing typed.
- [ ] With Accessibility off: the text is copied and the banner says to press ⌘V.
- [ ] Polish with your AI on: the text comes back polished, or as tidied after 6 s without an answer.
- [ ] The AI chat's microphone: dictate a question into the input, then send it.
- [ ] After two quiet minutes, `needle-helper` is gone from Activity Monitor.

### AI using the notch

With Gemini, Claude or GPT active (`debug.sh ai-ask`, `ai-decide`, `ai-undo`, `ai-stop` and `status` script these):

- [ ] "Add buy milk to my to-dos for tomorrow": a card waits for Allow; after Allow the to-do is on tomorrow's list and the answer says so; Undo on the card removes it.
- [ ] "What's on my agenda?": a quiet "Checked your calendar" line, then the answer. Without Calendar access, the card offers Allow Calendar.
- [ ] "Start a 1 minute countdown" then Don't: the card is struck through and the answer accepts it.
- [ ] "Add three to-dos for tomorrow: …": three cards; Allow all adds all three; Undo takes each back.
- [ ] Stop while a card waits: it shows Stopped and nothing changes.
- [ ] `/todo test`, `/timer 1m`, `/focus`, `/next`: run at once, show a done card, and never reach the model.
- [ ] A question whose answer failed (server off), then a new question: the AI doesn't act on the failed one.
- [ ] A local model without tool support: it answers without tools and the notice says so.

### Accessibility

- [ ] Reduce Motion on: the notch fades instead of springing; the equalizer bars, glow and LED title are still; no confetti or ripple; a flicked shelf item disappears without flying.
- [ ] Reduce Motion with a capture: flicking a tile off the shelf removes it without the throw.
- [ ] VoiceOver reads the header tabs and the more grid, playback controls, reminders, the pin and ⌘K buttons, the palette rows, the LED title (as plain text) and the mascot. Shelf items offer Open, Show in Finder and Remove actions.

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
| Screen Recording | The first screenshot or recording. Choosing a window to record uses macOS's picker instead, which asks for nothing | `CaptureService.ensureScreenPermission` |
| Microphone | Only when a recording starts with Capture › Microphone on, or the first dictation | `CaptureService.microphoneAllowed`, `MicRecorder.requestPermission` |
| The folder macOS saves screenshots in (usually Desktop) | Only when the Capture module is open with "List screenshots taken with ⌘⇧3…" on | `CaptureService.startQuery` |
| Downloads folder (may be asked) | Only with Settings › "Show download progress" on | `DownloadsService.settingsChanged` |
| Accessibility | Turning on the volume HUD, or dictation's Fn key; Xotch only opens the settings pane | `MediaKeys.requestPermission`, `PrivacyPane.accessibility` |
| Input Monitoring | Never | — |

Hidden modules (Settings › Modules) stop their background work: the Now Playing helper exits and the clipboard watcher stops.
