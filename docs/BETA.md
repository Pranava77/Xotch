# Private beta

## Before sending a build

1. Set `Diagnostics.supportAddress` in `Sources/Brim/Services/Diagnostics.swift`, so "Send Feedback…" and crash reports are addressed to you.
2. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
3. Run `./scripts/package-beta.sh`. It builds a release app, checks the signature and writes `build/Brim-<version>-<build>.zip` with its SHA-256.
4. Strongly recommended: sign with a Developer ID and notarize before sending the build to anyone.
   - Without that, every tester has to override Gatekeeper by hand (below).
   - macOS may also ask for Calendar access again after each update.
   - Use `SIGN_IDENTITY="Developer ID Application: …" ./scripts/package-beta.sh`, then `xcrun notarytool submit` and `xcrun stapler staple`.

Still to do for a beta channel: automatic updates. Adding Sparkle needs the Sparkle package, EdDSA signing keys, and an appcast hosted on your site.

## For testers

**Needs** macOS 14 Sonoma or later, on an Apple silicon or Intel Mac. It works best on a MacBook with a notch; other displays get a drawn notch.

### Install

1. Unzip `Brim-….zip` and drag Brim to Applications.
2. Open Brim. macOS will probably say it can't check the app for malicious software. Close that message.
3. Open System Settings › Privacy & Security, scroll to Security, and press **Open Anyway** next to Brim.
4. Brim appears in the menu bar; there's no Dock icon. Hover over the notch to peek, then click to open.

### What to try over the week

- **Every day:** Home, Now Playing (Music, Spotify, a browser), Calendar, Timers.
- **Clipboard:** copy things and search them later. macOS asks once whether Brim may read the clipboard.
- **Shelf:** drag a file towards the notch, drop it, then drag it out somewhere else.
- **Make it yours:** try the themes in Settings › Appearance, ⌘K in the open notch, scrolling on the closed notch for volume, and flicking a file off the Shelf.
- **Different setups:** full-screen apps, an external display, sleep and wake.
- **Optional:** add the Claude Code hook in the Claude Code module.

### Sending feedback

- **Menu bar icon › Send Feedback…** opens an email with your Brim and macOS versions filled in.
- **If Brim quits unexpectedly:**
  1. Turn on Settings › Privacy and feedback › "Keep crash reports I can choose to send".
  2. The menu bar then offers **Email Report…**, which attaches macOS's crash report.
  3. Nothing is sent unless you send that email.

### Privacy

Everything Brim keeps is stored on your Mac, in `~/Library/Application Support/Brim`. Brim doesn't connect to any online service.
