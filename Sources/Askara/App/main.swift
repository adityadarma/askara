import AppKit
#if ASKARA_CEF
import CEFBridge
#endif

// App entry point. No storyboard/XIB, to stay lightweight.
MainActor.assumeIsolated {
    CrashReporter.shared.start()
#if ASKARA_CEF
    let app = AskaraCEFBridge.application
#else
    let app = NSApplication.shared
#endif
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
    // CEF shutdown must happen after AppKit finishes session termination. Calling it from
    // applicationShouldTerminate deadlocks Chromium's popup/session teardown watchdog.
    CEFHost.stop()
}
