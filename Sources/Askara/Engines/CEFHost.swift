import Foundation

#if ASKARA_CEF
import CEFBridge
#endif

@MainActor
enum CEFHost {
    private(set) static var initializationError: String?
#if ASKARA_CEF
    private static var smokeContext: AskaraCEFRequestContext?
#endif

    static var isCompiledIn: Bool {
#if ASKARA_CEF
        true
#else
        false
#endif
    }

    static var isInitialized: Bool {
#if ASKARA_CEF
        AskaraCEFBridge.isInitialized
#else
        false
#endif
    }

    static func start() {
#if ASKARA_CEF
        guard !AskaraCEFBridge.isInitialized else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("Askara/Engines/Blink", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try AskaraCEFBridge.initialize(withRootCachePath: root.path)
            AskaraCEFBridge.whenReady {
                guard let marker = ProcessInfo.processInfo.environment["ASKARA_CEF_SMOKE_FILE"] else { return }
                do {
                    let contextPath = root.appendingPathComponent("SmokeProfile", isDirectory: true)
                    try FileManager.default.createDirectory(at: contextPath, withIntermediateDirectories: true)
                    smokeContext = try AskaraCEFBridge.createRequestContext(atCachePath: contextPath.path)
                    try Data("initialized\n".utf8).write(to: URL(fileURLWithPath: marker), options: .atomic)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { NSApp.terminate(nil) }
                } catch {
                    initializationError = error.localizedDescription
                    Log.error("Askara: CEF request context failed: \(error.localizedDescription)")
                }
            }
        } catch {
            initializationError = error.localizedDescription
            Log.error("Askara: CEF initialization failed: \(error.localizedDescription)")
        }
#endif
    }

    static func stop() {
#if ASKARA_CEF
        smokeContext?.invalidate()
        smokeContext = nil
        AskaraCEFBridge.doMessageLoopWork()
        AskaraCEFBridge.shutdown()
#endif
    }
}
