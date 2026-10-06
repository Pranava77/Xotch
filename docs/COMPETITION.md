# What else lives in the notch

Checked 6 October 2026, after a first pass on 22 September. **Read the sources
with suspicion:** almost every "best Mac notch apps, compared honestly" page is
published by one of the apps in its own table. So this pass went to each app's
own site or repository wherever possible. Even so, what's below is what the
vendors claim, not what we measured. The site's comparison
([index.html](index.html#compare)) is built from this page.

## The field

| App | Price | Without a notch | Oldest macOS | Known for |
|---|---|---|---|---|
| **Notchy** | Free, donations | **Yes**, a floating pill | 13 | 70-plus features: lyrics, Face Unlock, OCR, launcher, Claude Code activity and approvals |
| NotchNook | $25 one-time, or a subscription | Yes | 14.6 | The established, polished widget dock. September reviews report slow support |
| Alcove | $14.99 | Not stated | 15 | Animation polish, Live Activities, Lock Screen widgets |
| The Boring Notch | Free, GPL-3.0, ~11k stars | Yes | 14 | The free default: music, shelf with AirDrop, HUDs. Unsigned |
| Atoll | Free, GPL-3.0 | **No**, needs a notched MacBook | 14 | Media, timers, clipboard, system stats |
| Crest | $24.99 Pro bundle, or $2.99/mo / $14.99/yr | Yes, a pill | 14 | **Coding-agent approvals** (Claude Code, Codex, Copilot CLI), GitHub PRs and CI, lyrics, to-dos; sister apps for screenshots and on-device meeting notes |
| Droppy | $9.99 one-time | Yes, a floating shelf | 14 | Shelf, clipboard, window snapping; 35 add-ons including lyrics, agent status and on-device transcription |
| OneNotch | Free, Pro $9.99 | Not stated | – | – |
| NotchBox | Free, Pro $4.99 | Not stated | – | Water, counters, days-left |
| Brow | Free, Pro $49/year | Not stated | – | The only subscription at that price |
| MacNotch | Setapp | Yes | – | Calendar, Reminders and tasks on one rail |
| NotchNest | Free, then $2.99/mo, $14.99/yr or lifetime | Not stated | 14 | On-device AI clipboard |

Prices and features for the last five are from the September pass and weren't
re-checked.

## What changed since September

**Coding agents became table stakes.** In September, "live Claude Code status"
looked like Xotch's own ground. By October:
- Notchy shows agent activity (turns, prompts, cost per turn) and approves
  Claude Code's permission requests from the notch.
- Crest approves requests from Claude Code, Codex and Copilot CLI, and adds
  GitHub PRs and CI.
- Droppy follows Claude, Codex, Cursor and Antigravity through an add-on.

Xotch shows the status and usage but **can't approve a request** from the notch.
That is the most obvious gap to close.

**Voice arrived, but not as dictation.**
- Droppy's Voice Transcribe records or imports audio, transcribes it on the Mac
  with Whisper or Parakeet, and copies the text.
- Crest's sister app Minutes writes meeting notes on the Mac (macOS 26, Apple
  silicon).

Neither is hold-a-key dictation that types into the app you're in.

## Where Xotch stands

**Only Xotch, of the eight compared on the site:**
- **An AI chat in the notch**, with Claude, GPT, Gemini, Groq, OpenRouter or a
  local model.
- **An AI that acts on your day:** to-dos, timers, notes, calendar and music,
  each change on an Allow card, most of them undoable.
- **Push-to-talk dictation into any app**, transcribed on the Mac by Whistle.
- **A companion character** (page mascot).

**Same ground as the rest:** music, calendar, to-dos, focus timers, clipboard,
shelf, capture, HUDs, themes, a command palette, and a notch on every display.

**Missing, against the leaders:**
- Approving coding-agent requests (Notchy, Crest).
- Synced lyrics (Notchy, Crest, Droppy).
- Face Unlock, OCR and an app launcher (Notchy).
- Window snapping (Droppy).
- GitHub integration (Crest).
- macOS 13 (Notchy).
- Signing and notarisation (Crest and Droppy have it; Xotch's beta doesn't).

## The strategic read

Feature count isn't winnable against a free app with 70-plus features, and
coding-agent status alone no longer sets anyone apart. The defensible ground is
**the assistant**: an AI you can talk to at the top of the screen, by voice or by
typing, that does things in your day with your permission. Nobody else in the
category has chat, actions with approval, and dictation together.

Three things would make that position hard to argue with:
1. Agent approvals, so developers don't need a second notch app.
2. Signing and notarisation, which competitors at every price already have.
3. Using dictation to talk to the AI as well as to type.

## Sources (6 October 2026)

- [notchy.dev](https://notchy.dev/)
- [NotchNook on MacUpdate](https://notchnook.macupdate.com)
- [tryalcove.com](https://tryalcove.com)
- [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch)
- [Ebullioscopic/Atoll](https://github.com/Ebullioscopic/Atoll)
- [crestnotch.app](https://crestnotch.app)
- [getdroppy.app](https://getdroppy.app/), and [Droppy's voice transcription post](https://getdroppy.app/blog/voice-transcription-mac-private)
- Round-ups, each from a competitor:
  - [notchy.dev/best-mac-notch-apps](https://notchy.dev/best-mac-notch-apps/)
  - [getdroppy.app/blog/best-mac-notch-apps-2026](https://getdroppy.app/blog/best-mac-notch-apps-2026)
  - [favtray.com](https://favtray.com/blog/dynamic-island-for-mac-notch-apps)
  - [macnotch.io](https://macnotch.io/compare/best-mac-notch-apps)
