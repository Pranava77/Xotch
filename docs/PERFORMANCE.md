# Performance

Budget: **under 0.5% CPU and under 80 MB of memory while idle**, with nothing that keeps working while the notch is closed.

Measured on a 14" MacBook Pro (Mac17,9, Apple M5 Pro), macOS 26.6.2, debug build 0.2.0 (2), with every module shown, the Smoke Glass theme, and Now Playing connected to a paused Chrome tab.

## Results

`scripts/perf.sh 10` (each state averaged over about 10 seconds, after a 3-second settle), after Phase 4:

| State | CPU | Energy impact | Idle wakeups | Memory |
|---|---|---|---|---|
| Closed, nothing live | 0.00% | 0.00 | 0.0/s | 18 MB |
| Open on Home (measured when Home still had the mascot) | 0.00% | 0.00 | 0.0/s | 32 MB |
| Open on Now Playing (glow, scrolling LED title) | 0.10% | 0.10 | 0.0/s | 38 MB |
| Open on Calendar | 0.00% | 0.00 | 0.5/s | 36 MB |
| Open on Clipboard | 0.00% | 0.00 | 0.5/s | 37 MB |
| Open on Shelf | 0.00% | 0.00 | 0.5/s | 37 MB |
| Open on System | 0.60% | 0.60 | 0.5/s | 38 MB |
| Open on Capture | 0.00%* | 0.00* | — | — |
| Closed, recording indicator (red timer) | 0.42%* | 0.42* | — | — |
| Recording the screen with system audio | ~1%* | — | — | — |
| Open on Claude Code | 0.00% | 0.00 | 0.5/s | 44 MB |
| Open on Timers | 0.10% | 0.10 | 0.5/s | 44 MB |
| Closed, music bars (built-in animation) | 0.00% | 0.00 | 0.7/s | 41 MB |
| Closed, music bars following real sound (tap on, nothing playing) | 0.17% | 0.17 | — | 41 MB |
| Closed, timer counting down (ring) | 0.44% | 0.44 | 1.0/s | 42 MB |
| Closed, Claude working (pulse) | 0.00% | 0.00 | 1.0/s | 42 MB |
| Closed, download progress | 0.00% | 0.00 | 1.0/s | 47 MB |
| Open, command palette | 0.10% | 0.10 | 1.0/s | 54 MB |

\* The Capture rows were measured later, back to back against a closed notch, on a Mac that was in use, so only their CPU figures are worth comparing with the rest of the table. The first time Capture opens, it starts a Spotlight query for the screenshots you take with ⌘⇧3 and ⌘⇧4; that query then stays alive for two minutes after the notch closes, so opening Capture again costs nothing. Without that, each open cost about 3% for a moment.

## A second display

Every screen gets its own notch and its own panel, so the cost is per screen. On this Mac with the built-in display plus a 3440×1440 ultra-wide — one hardware notch, one drawn in the external's menu bar — a freshly launched debug build sat at **80 MB** with both notches closed, against the 18 MB single-screen figure in the table above. Most of that is the second window's backing store at the panel's full 1236×624, which is allocated whether or not the notch is open.

To-dos cost nothing while open: a short list, nothing polls, and the only timer is one sleep until midnight.

Recording a 1800×1169 display at 60 fps with system audio cost about 1 percentage point of CPU in Xotch over a closed-notch baseline of 1.0% on a busy Mac. That is the red timer plus handing frames over; ScreenCaptureKit encodes the H.264 in macOS's own processes, so the rest of the cost doesn't appear against Xotch. The resulting file is about 1.9 MB per second of screen.

The Media helper process (`perl` running `MediaRemoteBridge`) uses 0% CPU and about 4 MB.

The music bars cost nothing with their built-in animation. With Settings › "Move the music bars with the real sound" on, Xotch reads the audio tap and updates the bars 20 times a second while they're showing, and stops the tap when they're hidden. Measured back to back: 0.17% with the bars up, 0.00% with them hidden. The analysis runs on every other window of audio whatever is playing; with music, each update also moves four layers. That case hasn't been measured yet, because it needs music playing and the permission granted.

Measurements are noisy while the Mac is in use: one run with Settings open and the pointer moving read 12–20% for the same state, and 0.17% again once things were quiet.

The first time each module opens after launch costs a short burst of CPU (loading its data, a Claude log scan of about 0.9 s, compiling the Metal shaders in about 0.1–0.25 s on a background thread). The numbers above are after that settles. Moving the pointer wakes Xotch for every move, because it watches for the pointer reaching the notch; each event is a rectangle check. Wakeup counts in the table go up whenever the Mac is being used during the run.

## What Phase 4 changed

| Problem | First version | Now | Fix |
|---|---|---|---|
| Artwork glow and LED title | 4.3% CPU and 138 MB with Now Playing open | 0.10% and 38 MB | Metal draws each effect once into an image; Core Animation cross-fades the glow and moves the LED strip a whole column at a time. The LED sign never needed more than 14 steps a second. |
| Drop ripple | A Metal view that stayed in the open notch | Only exists for the one second it plays | `RippleOverlay` adds its Metal view per ripple. Shaders compile as soon as a file drag starts, so the first ripple isn't missed. |
| Timer ring, Claude pulse, confetti | — | 0% | Core Animation layers and a `CAEmitterLayer`, animated by the window server |

## What Phase 5 changed

| Problem | Before | After | Fix |
|---|---|---|---|
| Music equalizer beside the notch | 6.7% CPU for as long as music plays | 0.0% | Bars are Core Animation layers, animated by the window server instead of redrawn by SwiftUI 12 times a second |
| SF Symbol effects (banner bounce, play/pause and reminder swaps) | ~130 MB while a banner shows; 121 MB opening Now Playing | 19 MB; 25 MB | Replaced with a SwiftUI spring (`popOnChange`) and scale-fade (`swapTransition`). Symbol effects load ~100 MB of symbol animation data |
| Claude log scan (77 MB of logs) | Peak memory held by per-line Foundation objects | 30 MB peak | `autoreleasepool` around each parsed line |
| System module | 1.3% CPU while open | 0.53% | Disk and battery read every 10 s instead of every 2 s |
| Clipboard watcher | Wakes every 0.6 s | Every 1 s with 0.5 s tolerance | macOS can batch the wakeup with other work |
| CPU usage counters | Would crash (UInt64 underflow) once a 32-bit tick counter wraps, after roughly four weeks of uptime | Wrapping arithmetic | `StatsService.cpuUsage(from:to:)`, covered by the self-test |

## Leaks

- `scripts/debug.sh rebuild 30`, three times (90 full rebuilds of the notch windows): memory settles at 58 MB and stays there.
- One notch window remains afterwards; none are left behind.
- `leaks` reports 266 leaks (13 KB), all inside Apple's App Intents XPC connection (`com.apple.linkd.autoShortcut`). The count is the same before and after the rebuilds. No Xotch objects are listed.

Debug builds are signed with `get-task-allow` (`Resources/Xotch.debug.entitlements`) so `leaks`, `sample` and `vmmap` can inspect them; release builds aren't.

## Known: transient graphics memory when switching modules

In a fresh session, switching between modules while the notch is open can briefly raise memory to about 130 MB for less than a second, after which it returns to 30–40 MB. `footprint` attributes the extra 93 MB to "Owned physical footprint (graphics)": about 35 buffers, each roughly the size of the open notch, that SwiftUI and Core Animation allocate while rendering the new module.

It isn't caused by the transition style: plain cross-fades and a rectangular clip gave the same peak. `scripts/switch-peak.sh` reproduces it. Once Xcode is installed, profile it with Instruments (Allocations plus the Metal/VM Tracker instruments) to find which layers need off-screen passes.

## Reproducing

```bash
./scripts/build-app.sh debug --run
./scripts/perf.sh 12          # the table above
./scripts/switch-peak.sh      # the transient graphics peak
./scripts/debug.sh rebuild 30 # then: leaks $(pgrep -x Xotch)
```

`perf.sh` opens the notch on each module without taking keyboard focus. Keep the pointer still while it runs, because pointer movement adds wakeups.
