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

WebKit is the built-in runtime. Blink will be added as a CEF-backed adapter under `Engines`.
Gecko remains unavailable until a supported macOS embedding runtime is selected.
