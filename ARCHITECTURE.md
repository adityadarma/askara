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
- `Bookmarks`, `Downloads`, `Extensions`, `Profiles`, `Privacy`, `Settings`, `Sync`, `Import`:
  feature-owned UI and services.
- `DeveloperTools`: source viewer and task manager.
- `UI`: reusable AppKit views without feature ownership.
- `Infrastructure`: logging, crash reporting, and OS-level metrics.

## Core Target

- `Browser`: sessions, device presets, zoom, and hibernation policy.
- `Navigation`: address parsing and suggestions.
- `Bookmarks`, `History`, `Downloads`, `Profiles`, `Privacy`, `Preferences`, `Import`:
  platform-independent feature logic.
- `Persistence`: generic storage helpers.

## Dependency Rules

1. Feature UI talks to shared state through `BrowserServices` or its feature-owned service.
2. Browser pages use the system `WKWebView`; Apple supplies WebKit with macOS, so no rendering
   framework is copied into the app bundle.
3. Put reusable business rules in `AskaraCore`. Keep framework-specific behavior in `Askara`.
4. Prefer one primary responsibility per file. Split unrelated models instead of creating generic
   `Models`, `Helpers`, or `Utils` files.
5. Keep controller state private. Split a large controller only when the extracted component can
   expose a narrow interface without widening internal state.

## WebKit

Askara exclusively embeds Apple's `WKWebView`. Normal profile windows use a persistent
`WKWebsiteDataStore`; private windows use a non-persistent store. `Tab` owns the live `WKWebView`
directly while awake, and `Tab.interactionState` preserves back/forward history and scroll position
while Memory Saver releases the view.

Profiles created by older multi-engine builds remain compatible. The obsolete `browserEngineID`
JSON field is ignored and removed on the next profile-file rewrite. The legacy CEF cache under
`~/Library/Application Support/Askara/Engines/Blink` is deleted without touching history,
bookmarks, permissions, or session metadata.

## Passwords

Askara has no built-in password vault. Password management is delegated to an optional Safari Web
Extension such as Bitwarden: when the user has installed and enabled it, it is loaded per profile
through `WKWebExtensionController`; when it is absent, Askara runs without any password features.

## Local Persistence

Completed download history and scan metadata are persisted under Application Support. Download
completion and failure can produce macOS local notifications after user authorization. The selected
encrypted-sync folder stores a security-scoped bookmark locally; the bookmark is not copied into the
sync snapshot.
