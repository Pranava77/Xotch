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
2. Open Xotch. macOS will probably say it can't check the app for malicious software. Close that message.
3. Open System Settings › Privacy & Security, scroll to Security, and press **Open Anyway** next to Xotch.
4. Xotch appears in the menu bar; there's no Dock icon. Hover over the notch to peek, then click to open.

### What to try over the week

- **Every day:** Home, Now Playing (Music, Spotify, a browser), Calendar, Timers.
- **Clipboard:** copy things and search them later. macOS asks once whether Xotch may read the clipboard.
- **Shelf:** drag a file towards the notch, drop it, then drag it out somewhere else.
- **To-dos:** put today's to-dos in, tick them off, and right-click one to move it to tomorrow or someday.
- **Capture:** take a screenshot of an area, a window and the screen, record a few seconds of screen, and check that your own ⌘⇧4 screenshots turn up there too. macOS asks for Screen Recording the first time; screen recording itself needs macOS 15.
- **Make it yours:** try the themes in Settings › Appearance, ⌘K in the open notch, scrolling on the closed notch for volume, and flicking a file off the Shelf.
- **Different setups:** full-screen apps, an external display, sleep and wake.
- **Optional:** add the Claude Code hook in the Claude Code module.

### Sending feedback

- **Menu bar icon › Send Feedback…** opens an email with your Xotch and macOS versions filled in.
- **If Xotch quits unexpectedly:**
  1. Turn on Settings › Privacy and feedback › "Keep crash reports I can choose to send".
  2. The menu bar then offers **Email Report…**, which attaches macOS's crash report.
  3. Nothing is sent unless you send that email.

### Privacy

Everything Xotch keeps is stored on your Mac, in `~/Library/Application Support/Xotch`. Xotch doesn't connect to any online service.
