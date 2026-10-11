# Private beta

## Before sending a build

1. Set `Diagnostics.supportAddress` in `Sources/Xotch/Services/Diagnostics.swift`, so "Send Feedback…" and crash reports are addressed to you.
2. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
3. Run `./scripts/package-beta.sh` for a zip, or `./scripts/package-dmg.sh` for a drag-to-Applications disk image. Both build a release app, check the signature and print a SHA-256.
4. Strongly recommended: sign with a Developer ID and notarize before sending the build to anyone.
   - Without that, every tester has to override Gatekeeper by hand (below).
   - macOS may also ask for Calendar access and Screen Recording again after each update.
   - Use `SIGN_IDENTITY="Developer ID Application: …" ./scripts/package-beta.sh`, then `xcrun notarytool submit` and `xcrun stapler staple`.

Still to do for a beta channel: automatic updates. Adding Sparkle needs the Sparkle package, EdDSA signing keys, and an appcast hosted on your site.

## For testers

**Needs** macOS 14 Sonoma or later, on an Apple silicon or Intel Mac. It works best on a MacBook with a notch; other displays get a drawn notch.

### Install

1. Open `Xotch-….dmg` (or unzip `Xotch-….zip`) and drag Xotch to Applications.
2. Open Xotch. Beta builds aren't notarised yet, so macOS says it "could not verify Xotch is free of malware". Press **Done**, not Move to Trash.
3. Open System Settings › Privacy & Security, scroll down to Security, and press **Open Anyway** next to "Xotch was blocked". Confirm with your password or Touch ID, then press **Open**. The button only shows for about an hour after step 2.
4. Xotch appears in the menu bar; there's no Dock icon. Hover over the notch to peek, then click to open.

If **Open Anyway** doesn't appear, run this once in Terminal, then open Xotch as usual:

```bash
xattr -dr com.apple.quarantine /Applications/Xotch.app
```

It removes the "downloaded from the internet" mark from Xotch only. Don't turn Gatekeeper off for the whole Mac.

### What to try over the week

- **Every day:** Home, Now Playing (Music, Spotify, a browser), Calendar, Timers.
- **Clipboard:** copy things and search them later. macOS asks once whether Xotch may read the clipboard.
- **Shelf:** drag a file towards the notch, drop it, then drag it out somewhere else.
- **To-dos:** put today's to-dos in, tick them off, and right-click one to move it to tomorrow or someday.
- **Capture:** take a screenshot of an area, a window and the screen, record a few seconds of screen, and check that your own ⌘⇧4 screenshots turn up there too. macOS asks for Screen Recording the first time; screen recording itself needs macOS 15.
- **Make it yours:** the mascot and the mirror on Home (Settings › Appearance), ⌘K in the open notch, scrolling on the closed notch for volume, and flicking a file off the Shelf.
- **Different setups:** full-screen apps, an external display, sleep and wake.
- **Optional:** add the Claude Code hook in the Claude Code module.

### Sending feedback

- **Menu bar icon › Send Feedback…** opens an email with your Xotch and macOS versions filled in.
- **If Xotch quits unexpectedly:**
  1. Turn on Settings › Privacy and feedback › "Keep crash reports I can choose to send".
  2. The menu bar then offers **Email Report…**, which attaches macOS's crash report.
  3. Nothing is sent unless you send that email.

### Privacy

Everything Xotch keeps is stored on your Mac, in `~/Library/Application Support/Xotch`. There's no account, analytics or telemetry. Xotch connects only to an AI service you add yourself (and only when you ask it something), and downloads the speech model once if you turn on dictation. Dictation and local models (Ollama, LM Studio) never leave your Mac.
