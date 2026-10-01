# Askara Architecture

Askara uses a feature-first source layout. The directory defines ownership; Swift types remain in
the existing `Askara` and `AskaraCore` modules.

## Modules

- `AskaraCore`: platform-independent models, policies, parsers, and persistence helpers.
- `Askara`: AppKit/WebKit integration, windows, views, and application services.

`AskaraCore` must not import AppKit or WebKit. `Askara` may depend on `AskaraCore`, never the reverse.

## App Target

- `App`: process entry point, app lifecycle, and shared application services.
- `Browser`: tabs, browser window, WebKit view support, and page-level browser behavior.
- `Engines`: rendering-engine adapters and runtime selection.
- `Bookmarks`, `Downloads`, `Extensions`, `Profiles`, `Privacy`, `Settings`, `Sync`, `Import`:
  feature-owned UI and services.
- `DeveloperTools`: source viewer and task manager.
- `UI`: reusable AppKit views without feature ownership.
- `Infrastructure`: logging, crash reporting, and OS-level metrics.

## Core Target

- `Browser`: sessions, engine selection, device presets, zoom, and hibernation policy.
- `Navigation`: address parsing and suggestions.
- `Bookmarks`, `History`, `Downloads`, `Profiles`, `Privacy`, `Preferences`, `Import`:
  platform-independent feature logic.
- `Persistence`: generic storage helpers.

## Dependency Rules

1. Feature UI talks to shared state through `BrowserServices` or its feature-owned service.
2. Rendering runtimes implement `BrowserEngineAdapter`; browser UI must not select a concrete
   runtime directly. Engine selection belongs to a profile; changing it recreates only that profile's
   windows and runtime while other profiles keep running.
3. Put reusable business rules in `AskaraCore`. Keep framework-specific behavior in `Askara`.
4. Prefer one primary responsibility per file. Split unrelated models instead of creating generic
   `Models`, `Helpers`, or `Utils` files.
5. Keep controller state private. Split a large controller only when the extracted component can
   expose a narrow interface without widening internal state.

## Engine Roadmap

WebKit is the built-in runtime. Each loaded profile owns one `BrowserEngineRuntime` and its
`BrowserEngineCapabilities`. Feature UI checks capabilities before exposing engine-owned behavior.

Blink runs through a bundled Chromium Embedded Framework (CEF) runtime. It is selectable only in
CEF builds where `CefInitialize` succeeded; otherwise the registry falls back to WebKit and the
profile reports `.webkit`, never Blink.

Tabs hold an engine-neutral `TabContent` (`nil` = asleep). `WebKitTabContent` wraps the existing
`WKWebView`, and WebKit-only features (extensions, PiP, find, print, Device Mode, snapshots,
process metrics) still reach it through `Tab.webView`, which is `nil` for other engines.
`BlinkTabContent` wraps a native CEF child view. A Blink profile owns one persistent request context
under `Engines/Blink/Profiles/<id>`; each private window gets its own in-memory context that is
dropped when the window closes. What Blink does not support yet is declared in
`BlinkEngineCapabilities` and hidden or disabled in the UI.

CEF uses Chromium's renderer and network stack, but it is not Google Chrome. Compatibility is not
guaranteed for Chrome Extension APIs, Google account services, Chrome Sync, Widevine/DRM, native
messaging, Chrome-specific UI, or every WebAuthn flow. Each capability must be enabled only after an
integration test proves the behavior in the bundled CEF version. Gecko remains deferred.

### CEF Development Build

Askara pins the official macOS arm64 minimal distribution to CEF
`154.0.32+g682c378+chromium-154.0.8037.58` (Chromium `154.0.8037.58`). Install and verify it with:

```sh
scripts/install-cef.sh
scripts/smoke-cef.sh
```

The vendor binary is stored under ignored `Vendor/cef/`. `scripts/bundle.sh --cef` enables the
`CEFBridge` SwiftPM target and bundles the versioned framework plus the macOS helper apps. CEF
launches each sub-process type from its own helper bundle (`Askara Helper (Renderer).app`, GPU,
Plugin, Alerts); a missing variant fails silently, e.g. pages never load without the renderer one.
The default `swift build` and `swift test` remain independent of the large vendor binary.

`scripts/smoke-cef.sh` runs the real tab stack on throwaway storage: a Blink profile, a normal and a
private window, navigation, release of every browser when windows close, and orderly shutdown.

Implementation order:

1. Runtime and capability contract, then migrate existing WebKit behavior behind it.
2. Bundle and boot CEF with an isolated request context per profile.
3. Navigation, popup/OAuth, website data, downloads, permissions, and content blocking.
4. Context menu, export/printing, DevTools, process management, media, and device emulation.
5. WebAuthn and extensions after dedicated compatibility tests, including Bitwarden.
