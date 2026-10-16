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
  Picture-in-Picture.
- **Languages**: English and Indonesian.

## Requirements

- macOS 15.4 or later (the minimum for `WKWebExtension`).
- Swift 5.9+ (Xcode or Command Line Tools).

## Install

Download `Askara-<version>-universal.zip` from the latest release (works on Apple Silicon and
Intel), unzip it, and move `Askara.app` to the Applications folder.

Askara is not notarized by Apple, so macOS blocks the first launch. Do one of these once:

- **System Settings:** open Askara and click Done on the warning. Then open System Settings >
  Privacy & Security, scroll down, and click Open Anyway.
- **Terminal:** `xattr -dr com.apple.quarantine /Applications/Askara.app`

In-app updates are not affected.

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
