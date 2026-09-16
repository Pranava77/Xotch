# Performance

Budget: **under 0.5% CPU and under 80 MB of memory while idle**, with nothing that keeps working while the notch is closed.

Measured on a 14" MacBook Pro (Mac17,9, Apple M5 Pro), macOS 26.6.2, debug build 0.2.0 (2), with every module shown and Now Playing connected to a paused Chrome tab. No payment or analytics keys were connected.

## Results

`scripts/perf.sh 12` (each state averaged over about 12 seconds, after a 3-second settle):

| State | CPU | Energy impact | Idle wakeups | Memory |
|---|---|---|---|---|
| Closed, nothing live | 0.00% | 0.00 | 3.0/s | 24 MB |
| Open on Home | 0.00% | 0.00 | 3.0/s | 29 MB |
| Open on Now Playing | 0.08% | 0.08 | 3.5/s | 33 MB |
| Open on Calendar | 0.07% | 0.08 | 3.8/s | 33 MB |
| Open on Clipboard | 0.00% | 0.00 | 4.0/s | 34 MB |
| Open on System | 0.53% | 0.53 | 4.0/s | 36 MB |
| Open on Weather | 0.00% | 0.00 | 4.0/s | 36 MB |
| Open on Revenue | 0.00% | 0.00 | 4.0/s | 36 MB |
| Open on Analytics | 0.00% | 0.00 | 4.0/s | 37 MB |
| Open on Claude Code | 0.00% | 0.00 | 4.0/s | 41 MB |
| Open on Timers | 0.08% | 0.08 | 4.0/s | 42 MB |
| Closed, music playing (equalizer) | 0.00% | 0.00 | 4.0/s | 41 MB |
| Closed, timer counting down | 0.52% | 0.52 | 4.0/s | 42 MB |

The Media helper process (`perl` running `MediaRemoteBridge`) uses 0% CPU and about 4 MB.

The first time each module opens after launch costs a short burst of CPU (loading its data, a Claude log scan of about 0.9 s). The numbers above are after that settles. Moving the pointer wakes Brim for every move, because it watches for the pointer reaching the notch; each event is a rectangle check.

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
- `leaks` reports 266 leaks (13 KB), all inside Apple's App Intents XPC connection (`com.apple.linkd.autoShortcut`). The count is the same before and after the rebuilds. No Brim objects are listed.

Debug builds are signed with `get-task-allow` (`Resources/Brim.debug.entitlements`) so `leaks`, `sample` and `vmmap` can inspect them; release builds aren't.

## Known: transient graphics memory when switching modules

In a fresh session, switching between modules while the notch is open can briefly raise memory to about 130 MB for less than a second, after which it returns to 30–40 MB. `footprint` attributes the extra 93 MB to "Owned physical footprint (graphics)": about 35 buffers, each roughly the size of the open notch, that SwiftUI and Core Animation allocate while rendering the new module.

It isn't caused by the transition style: plain cross-fades and a rectangular clip gave the same peak. `scripts/switch-peak.sh` reproduces it. Once Xcode is installed, profile it with Instruments (Allocations plus the Metal/VM Tracker instruments) to find which layers need off-screen passes.

## Reproducing

```bash
./scripts/build-app.sh debug --run
./scripts/perf.sh 12          # the table above
./scripts/switch-peak.sh      # the transient graphics peak
./scripts/debug.sh rebuild 30 # then: leaks $(pgrep -x Brim)
```

`perf.sh` opens the notch on each module without taking keyboard focus. Keep the pointer still while it runs, because pointer movement adds wakeups.
