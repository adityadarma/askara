# Askara

A native macOS browser built on AppKit and Apple WebKit (`WKWebView`). It ships no browser engine of
its own; the only bundled framework is Sparkle, for in-app updates.

## Features

- **Address bar**: suggestions from history and bookmarks, ranked by match quality, visit count, and
  recency; inline autocomplete; a web search row for the selected search engine.
- **Tabs**: pinned tabs, Search Tabs across windows, recently closed (⇧⌘T reopens a tab or window),
  split view, Memory Saver and per-site sleep, command palette.
- **Profiles**: separate data per profile; private windows use non-persistent storage.
- **History, Bookmarks, Downloads**: each in its own window with live search. Downloads show progress
  in the toolbar and send a macOS notification when they finish or fail.
- **Privacy**: block lists, per-site exceptions in the Privacy Dashboard, YouTube ad blocking.
- **Extensions**: Safari Web Extensions through `WKWebExtensionController`. Askara has no built-in
  password vault; use an extension such as Bitwarden.
- **Developer tools** (Develop menu): per-tab user agent, Device Mode, Disable Caches, JSON viewer,
  local certificates for development hosts, Clear Site Data, Copy as cURL, page QR code.
- **Other**: Reader, encrypted sync to a folder of your choice, import from other browsers,
  Picture-in-Picture (optionally placed anywhere on screen, see
  [Picture-in-Picture placement](#picture-in-picture-placement)).
- **Languages**: English and Indonesian.

## Requirements

- macOS 14 or later. Safari extension support (`WKWebExtension`) needs macOS 15.4 or later; on macOS 14 the extension UI is hidden.
- Swift 5.9+ (Xcode or Command Line Tools).

## Install

Download `Askara-<version>-universal.zip` from the latest release (works on Apple Silicon and
Intel), unzip it, and move `Askara.app` to the Applications folder.

Askara is not notarized by Apple, so macOS blocks the first launch. Do one of these once:

- **System Settings:** open Askara and click Done on the warning. Then open System Settings >
  Privacy & Security, scroll down, and click Open Anyway.
- **Terminal:** `xattr -dr com.apple.quarantine /Applications/Askara.app`

In-app updates are not affected.

## Picture-in-Picture placement

macOS snaps the Picture-in-Picture window to a screen corner when you let go of it. Askara can keep
it where you drop it, and open it at that spot next time. This is off by default and needs the
Accessibility permission, because the window belongs to a system process (`PIPAgent`), not to Askara.

1. Open Settings (⌘,) > General and turn on **Place Picture in Picture anywhere on screen**.
2. macOS asks for permission. Click **Open System Settings**. You can also open it yourself:
   System Settings > Privacy & Security > Accessibility.
3. Turn on the switch next to **Askara**. If it is not in the list, click **+**, choose
   `Askara.app`, and turn it on.
4. Start Picture-in-Picture, drag the window anywhere, and let go. It stays there.

Notes:

- Askara watches mouse clicks only to notice when you drag the Picture-in-Picture window, and it reads
  and sets only that window's position and size. It does not read other windows, keystrokes, or
  screen content, and it stores nothing except the last window position on this Mac.
- If the window still snaps to a corner, the permission is missing or stale. After an update or a
  rebuild with a different signature, select Askara in the Accessibility list, click **−**, then
  add it again.
- Turning the setting off, or removing the permission, brings back the normal macOS behavior.
- This relies on a private macOS component, so a future macOS update may change it.

## Build and run

```sh
swift build                    # debug build
scripts/bundle.sh              # build/Askara.app (release, native architecture)
scripts/bundle.sh --universal  # arm64 + x86_64
scripts/bundle.sh --install    # copy to /Applications
open build/Askara.app
```

The bundle version comes from `ASKARA_VERSION` and `ASKARA_BUILD`. Without
`ASKARA_SPARKLE_PUBLIC_KEY`, the updater is disabled (expected for local builds).

## Tests

```sh
scripts/test.sh
```

The script points Swift Testing at the Command Line Tools when Xcode is not installed. With Xcode,
plain `swift test` works too.

## Project layout

```
Sources/AskaraCore   pure logic, no AppKit/WebKit (parsers, suggestion ranking, models, persistence)
Sources/Askara       the AppKit/WebKit app (windows, tabs, feature UI, services)
Tests/               AskaraCoreTests (logic), AskaraTests (AppKit components)
Localization/        en.lproj, id.lproj
Resources/           app icon
scripts/             bundle, test, icon, signing certificate
```

`AskaraCore` must not import AppKit or WebKit. `Askara` depends on `AskaraCore`, never the reverse.
Testable business rules belong in `AskaraCore`.

## Signing and releases

- `scripts/make-signing-cert.sh` creates a self-signed "Askara Self-Signed" certificate in the login
  keychain. `bundle.sh` uses it automatically, so macOS permissions (Downloads, camera, Keychain) are
  not requested again on every build. Without the certificate, the app is signed ad hoc.
- `.github/workflows/release.yml` runs when a `v*` tag is pushed: tests, universal build, zip, EdDSA
  signature, `appcast.xml`, then a GitHub Release.
- CI secrets: `SPARKLE_PRIVATE_KEY`, `SELF_SIGN_P12_BASE64`, `SELF_SIGN_P12_PASSWORD`. CI variable:
  `SPARKLE_PUBLIC_KEY`.
- Without a Developer ID and notarization, Gatekeeper still blocks the first launch.
