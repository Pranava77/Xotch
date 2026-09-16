# Brim

**Your MacBook's notch, put to work.**

Brim turns the notch into a small control centre for your music, calendar, timers, files and clipboard. If you build products, it also shows today's sales, your site's visitors and what Claude Code is doing. It stays out of the way until you reach for it, and uses almost no battery while it waits.

> Brim is in private beta. Thanks for trying it. Tell us what you think from the menu bar icon › **Send Feedback…**

## How it works

- **Peek:** move the pointer onto the notch and it grows slightly. Keep it there and Brim opens.
- **Keep it open:** click the notch. It stays open until you press Esc or click somewhere else.
- **Glance:** while the notch is closed, live updates sit either side of the camera. A timer counts down with a ring around it, the song playing shows its artwork, and Claude Code pulses while it works. You also see download progress and today's sales.
- **Drop files:** drag any file towards the notch. The Shelf opens, and whatever you drop waits there until you need it.

## What's inside

| Module | What you get |
|---|---|
| **Home** | The time, the weather, your next meeting and what's playing, at a glance. Brim's little mascot naps when things are quiet and jumps for joy when you make a sale. |
| **Now Playing** | Artwork, a dot-matrix track display, a scrubber and controls. Works with Music, Spotify, your browser and any other app that plays audio. The notch glows in the album's colours. |
| **Calendar** | The next 7 days, one-click **Join** for Zoom, Google Meet and Teams, and reminders you can tick off. |
| **Timers** | Focus sessions with breaks, countdowns, and a stopwatch with laps. A notification tells you when time's up. |
| **Clipboard** | Everything you've copied, searchable, with pins for favourites. Anything a password manager marks as private is skipped. |
| **Shelf** | Somewhere to park files. Drag them out when you need them, AirDrop them, or flick them away. |
| **Notes** | A scratchpad that can sit beside the notch, plus notes that save as you type. |
| **System** | CPU, memory, network speed, disk space and battery health. |
| **Weather** | Now, the next 12 hours and the next 7 days, for where you are or a city you choose. |
| **Revenue** | Today's sales from Stripe, Polar and Dodo Payments. Each new sale arrives with a burst of confetti, and today's total can stay beside the notch. |
| **Analytics** | Live visitors, today's traffic, top pages and referrers from DataFast. |
| **Claude Code** | Today's tokens, replies and streak, plus whether each session is working, needs you or is done. |

Don't need something? Hide it in **Settings › Modules**. Hidden modules stop working in the background.

## Shortcuts and gestures

| To | Do this |
|---|---|
| Open and keep open | Click the notch |
| Switch module | Press ⌘1–⌘9, or swipe sideways with two fingers |
| Run a command | Press ⌘K |
| Change the volume | Scroll on the closed notch |
| Remove a file from the Shelf | Flick it upwards, or Option-click it |
| Use a file from the Shelf | Drag it anywhere, or double-click to open it |
| Close | Press Esc, or click anywhere else |

Keyboard shortcuts work once you've clicked the notch.

**⌘K** jumps to anything. For example:

| Type | To |
|---|---|
| `cal` | Open Calendar |
| `10 min` or `90s` | Start a timer |
| `pause` | Pause the music |
| `aurora` | Switch to the Aurora theme |
| A few words you copied earlier | Copy them again |

## Make it yours

Everything below is in the menu bar icon › **Settings…**.

- **Appearance:**
  - Themes: Midnight, Smoke Glass (Liquid Glass on macOS 26), Aurora, or your own colours. The closed notch always stays black, so it blends in with the camera.
  - Show or hide the mascot and the dot-matrix track display.
- **Opening:** open on hover or on click, how long to hover, haptic feedback.
- **Beside the notch:**
  - music, and whether its bars follow the real sound
  - download progress
  - scrolling for volume
- **Sales:** confetti for each sale, and an optional cash-register sound. Press **Celebrate** to try it.
- **Display:**
  - Which display gets the notch. Macs without a notch, and external displays, get one drawn for them.
  - Whether to hide the notch while an app is full screen.
- **General:** open Brim when you log in.

## Requirements

- macOS 14 Sonoma or later, on Apple silicon or Intel.
- Best on a MacBook with a notch.
- Liquid Glass needs macOS 26.
- Music bars that follow the real sound need macOS 14.2 or later.

## Install

1. Unzip the download and drag **Brim** to your Applications folder.
2. Open Brim.
3. If macOS says it can't check the app for malicious software:
   1. Close the message.
   2. Open **System Settings › Privacy & Security**.
   3. Choose **Open Anyway** next to Brim.

   Beta builds need this step; signed releases won't.
4. Brim appears in the menu bar; there's no Dock icon. Move the pointer to the notch to start.

## Connect your services

These are all optional.

### Revenue

Open the Revenue module, choose your provider and paste a read-only key:

| Provider | Key to create |
|---|---|
| Stripe | A restricted key with read access to Charges |
| Polar | An organization access token with the `orders:read` scope |
| Dodo Payments | An API key from Developer › API Keys |

### Analytics

Paste your DataFast website API key; it starts with `df_`. You'll find it in your site's settings.

### Claude Code

Usage stats work straight away, from Claude Code's logs on your Mac.

For live status, press **Add hook**. Brim first backs up `~/.claude/settings.json`, then adds a small entry so Claude Code can tell Brim what it's doing. **Remove hook** takes that entry out again.

Keys are checked when you add them, and kept in your Mac's Keychain.

## Privacy

- **No tracking:** no account, no tracking, no analytics.
- **Kept on your Mac:** your clipboard history, notes and shelf are stored in `~/Library/Application Support/Brim`, and your settings in Brim's preferences. API keys are kept in your Keychain.
- **Few connections:** Brim only contacts Open-Meteo for the weather, and the services you connect yourself.
- **Audio:** when the music bars follow the real sound, Brim only measures how loud the music is. Nothing is recorded or kept.
- **Crash reports:** never sent automatically. Turn on **Keep crash reports I can choose to send** and you can attach one to an email yourself.

### Permissions

Brim asks for a permission only when you use something that needs it:

| Permission | When Brim asks | What it's for |
|---|---|---|
| Calendars and Reminders | When you choose **Allow** in Calendar | Your events and reminders |
| Location | When you open Weather without choosing a city | A local forecast |
| Notifications | When you start your first timer | Telling you when time's up |
| Paste from other apps (macOS 26) | When you choose **Allow** in Clipboard | Keeping your clipboard history |
| System audio recording | Only if you turn on real sound for the music bars | Measuring how loud the music is |
| Downloads folder | macOS may ask if you turn on download progress | Showing how far a download has got |

Brim never asks for Accessibility, Screen Recording or Input Monitoring.

## Battery life

Brim uses no processor time while the notch is closed and nothing is happening. It stays under 1% in every state we've measured, with the notch open or with something live beside it. Anything that only matters on screen, like system stats and the weather, pauses when you can't see it.

## Troubleshooting

**The notch disappeared.**
Brim steps aside while an app is full screen. Leave full screen, or turn off **Settings › Display › Hide the notch while an app is full screen**.

**Now Playing is empty.**
Start playing something. If Brim says Now Playing isn't available, choose **Try again**.

**Clipboard history stays empty (macOS 26).**
Open the Clipboard module and choose **Allow**. Then set Brim to always allow under **Paste** in **System Settings › Privacy & Security**.

**The music bars don't follow the music.**
Allow Brim under **System Settings › Privacy & Security › Screen & System Audio Recording**, or turn real sound off to keep the built-in animation.

**No download progress.**
Progress only appears for apps that report it to macOS, such as Safari and Chrome. Check that **Show download progress** is on.

**macOS asked for Calendar access again after an update.**
Beta builds aren't signed yet, so macOS can ask again. Signed releases won't.

**⌘1–9 or ⌘K does nothing.**
Click the notch first, so Brim receives your keyboard input.

## Uninstall

1. If you added the Claude Code hook, press **Remove hook** in the Claude Code module.
2. Quit Brim from the menu bar icon, then move it from Applications to the Trash.
3. To remove everything else as well:
   - delete `~/Library/Application Support/Brim` and `~/Library/Preferences/com.pranava.brim.plist`
   - in Keychain Access, delete the items named `com.pranava.brim`

---

Building Brim from source? See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
