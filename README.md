<p align="center">
  <img src="docs/images/icon.png" width="104" alt="Xotch's icon: Adiyogi, with a topknot, crescent moon, closed eyes and a glowing third eye, on a dark rounded square">
</p>

<h1 align="center">Xotch</h1>

<p align="center">
  <strong>The notch that does the work.</strong><br>
  An AI that acts with your permission, dictation that never leaves your Mac, and your whole day, one hover away.
</p>

<p align="center">
  <a href="#get-the-beta"><strong>Get the beta</strong></a>
  &nbsp;·&nbsp;
  <a href="docs/index.html">Website and comparison</a>
  &nbsp;·&nbsp;
  <a href="docs/GUIDE.md">User guide</a>
  &nbsp;·&nbsp;
  <a href="#for-engineers">For engineers</a>
</p>

<p align="center">
  <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square">
  <img alt="Native Swift" src="https://img.shields.io/badge/native-Swift%20%2F%20SwiftUI-111111?style=flat-square">
  <img alt="No tracking" src="https://img.shields.io/badge/tracking-none-30C26A?style=flat-square">
  <img alt="Private beta" src="https://img.shields.io/badge/status-private%20beta-FF9F0A?style=flat-square">
</p>

<p align="center">
  <img src="docs/images/hero.jpg" alt="Xotch open at the top of a Mac screen: Home's bento of tiles for the song playing, a page mascot, the next meeting with a Join button, a focus timer, to-dos and Claude Code">
</p>

## In one minute

- **What it is.** A native macOS app that turns the MacBook's notch, or a drawn one on any display, into a control surface for the things people do fifty times a day.
- **Who it's for.** Knowledge workers and developers who live on a laptop and want AI, capture and focus tools without another window, tab or subscription.
- **Why now.** Assistants are moving from answering to acting. Xotch puts that at the top of the screen, and makes every action visible and approved first.
- **What's different.** Of the eight notch apps compared, the only one with an AI chat, and the AI can act on your day, changing things only after you click Allow. Push-to-talk dictation into any app runs on the Mac, more than 150 times faster than real time. And a character keeps you company. The full comparison is on [the website](docs/index.html#compare).
- **Where it stands.** A working private beta: every claim below is measured or tested in this repository.

## What it does

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>Ask, and it acts</h3>
      <p>Chat with Claude, GPT, Gemini or a local model through Ollama or LM Studio, from any app with <kbd>⌘⇧Space</kbd>. The AI can check your calendar, to-dos and timer, and add a to-do, start a focus session, write a note or add an event. <b>Nothing changes until you click Allow</b>, and most actions can be undone from the card.</p>
    </td>
    <td width="50%"><img src="docs/images/ai-tools.jpg" alt="The AI planning an afternoon: it checked the calendar, added a to-do, and is waiting for Allow on a focus timer and a calendar event"></td>
  </tr>
  <tr>
    <td valign="top">
      <h3>Talk instead of typing</h3>
      <p>Hold <kbd>Fn</kbd> anywhere, speak, let go: the words appear where you're typing, tidied up. Speech becomes text <b>on the Mac</b> with Cactus's Whistle model, five seconds of speech in about 30 ms. Your voice is never saved or sent.</p>
    </td>
    <td><img src="docs/images/module-dictation.jpg" alt="Dictation listening: a red stop button and the sentence heard so far"></td>
  </tr>
  <tr>
    <td valign="top">
      <h3>Run your day</h3>
      <p>Home shows what's playing, your next meeting with a Join button, a focus timer, today's to-dos and what Claude Code is doing. Calendar, clipboard history, a file shelf, screenshots and screen recording are one tab away. While the notch is closed, the ears beside the camera take turns showing what's live.</p>
    </td>
    <td><img src="docs/images/module-todos.jpg" alt="Today's to-dos in the open notch"></td>
  </tr>
  <tr>
    <td valign="top">
      <h3>Make it yours</h3>
      <p>A page mascot watches your pointer from the ear and from Home, and reacts when you click it. Pick from twelve characters, put a mirror on Home for a look before a call, and choose which modules appear.</p>
    </td>
    <td><img src="docs/images/ears-mascot.jpg" alt="A small mascot in the ear beside the notch"></td>
  </tr>
</table>

## Why Xotch

| | Xotch | The rest of the category (checked 6 October 2026) |
|---|---|---|
| AI assistant | **Chat with Claude, GPT, Gemini or a local model**, which reads and **changes your to-dos, timer, notes and calendar after you click Allow** | No AI chat. Notchy, Crest and Droppy approve or follow coding agents; Droppy has AI image tools |
| Voice | **Hold Fn and talk; the text lands in whatever app you're in**, transcribed on the Mac | Droppy transcribes recordings on the Mac and copies the result; Crest transcribes meetings |
| Coding agents | Live Claude Code status in the ear, plus usage | Now common: Notchy, Crest and Droppy follow Claude Code, and Notchy and Crest approve its requests |
| Privacy | No account, no analytics. Local models and dictation keep everything on the Mac | Varies by app |
| Character | A mascot that watches the pointer and reacts | Not offered |

The honest picture: Notchy (free) and Crest and Droppy (paid) cover more ground in media, shelves and utilities, with lyrics, launchers and window tools that Xotch doesn't have. Xotch's bet is the assistant: an AI you can talk to, at the top of the screen, that does things in your day with your permission. The [website](docs/index.html#compare) compares eight apps feature by feature, with pros and cons for each, Xotch included; the research behind it, with sources, is in [COMPETITION.md](docs/COMPETITION.md).

## Proof

**Performance.** Measured with `top`, `sample` and `footprint` on an M5 Pro; method and history are in [PERFORMANCE.md](docs/PERFORMANCE.md).

| | Measured |
|---|---|
| Closed notch, three live activities taking turns | about 0.3% CPU |
| Memory, notch closed, fresh launch, two displays | 29 MB |
| Dictation: model load / 5 s of speech | 7 ms / about 30 ms |
| Dictation engine while idle | 0% CPU; it quits after two quiet minutes |
| The mascot's breathing and turns | No measurable CPU (Core Animation) |

**Privacy.** No account, no analytics, no telemetry.
- Dictation and local models never leave the Mac.
- With a cloud AI, the only data sent is your messages, your chosen context, any screenshot you attach, and what the AI looks up to answer. Clipboard and notes are sent only after you click Allow.
- API keys live in the Keychain.

**Quality.**
- A built-in self-test of more than fifty checks covers parsers, tool schemas, the speech engine's round trip, the mascot's motion and the audio analysis.
- A snapshot renderer draws every notch state to images, so changes are reviewed by eye.
- See [TESTING.md](docs/TESTING.md).

## Status and roadmap

**Now: private beta.** Feature-complete for daily use.
- Builds are not yet signed with a Developer ID, so testers approve Xotch once in System Settings.
- Each new build asks for permissions again.

**Next.**
1. Developer ID signing and notarisation, so installs and updates are one click and permissions survive updates.
2. Approving Claude Code's requests from the notch, which Notchy and Crest already offer.
3. Talking to the AI by voice, joining dictation and the assistant.
4. Automatic updates, then a public release.

## Get the beta

Xotch is in private beta. With an invite:

1. Unzip the download and drag **Xotch** to Applications.
2. Open it. If macOS says it can't check the app, choose **Open Anyway** in System Settings › Privacy & Security.
3. Move the pointer to the notch. Xotch lives in the menu bar.

**Requirements.**
- macOS 14 Sonoma or later, on Apple silicon or Intel.
- Dictation needs Apple silicon and macOS 26; screen recording needs macOS 15.

Setup for the AI, dictation and Claude Code is in the [user guide](docs/GUIDE.md).

## For engineers

- **Native and small:** Swift 6, SwiftUI and AppKit, with no third-party Swift dependencies. One borderless panel per display, sized once, with clicks passing through outside the notch.
- **Modules:** each feature implements `NotchModule` (Home, AI, Dictation, Media, Calendar, Timers, Clipboard, Shelf, Capture, To-dos, Notes, Stats, Claude Code).
- **AI:** one streaming backend per provider (Ollama, OpenAI-compatible, Anthropic, Gemini) emitting text and tool calls. A tool loop with approval cards runs over 20 notch tools.
- **Helpers in their own processes:**
  - `needle-helper` runs Whistle, because the engine can't unload its model;
  - a Perl-hosted bridge reads Now Playing, which macOS restricts to Apple-signed processes.
- **Debugging without a mouse:** `scripts/debug.sh` drives the running app (open, click, type, status, self-test, snapshots).

| Document | What's in it |
|---|---|
| [GUIDE.md](docs/GUIDE.md) | Every feature, setup, shortcuts, permissions, questions |
| [DEVELOPMENT.md](docs/DEVELOPMENT.md) | Building, debug commands, architecture notes |
| [PERFORMANCE.md](docs/PERFORMANCE.md) | Budgets, measurements, what was fixed and how |
| [TESTING.md](docs/TESTING.md) | Manual checks and the permission audit |
| [COMPETITION.md](docs/COMPETITION.md) | The notch-app market, with sources |

<sub>Speech recognition by [Whistle](https://huggingface.co/Cactus-Compute/whistle) from Cactus Compute (Apache 2.0). Characters from [page-mascot](https://github.com/nilbuild/page-mascot) by Kamran Ahmed (MIT). Xotch is a working name.</sub>
