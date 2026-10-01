#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// NSApplication must implement CefAppProtocol before CEF initializes on macOS. The bundled app
/// selects this class through NSPrincipalClass only when built with CEF.
@interface AskaraCEFApplication : NSApplication
@end

@interface AskaraCEFRequestContext : NSObject
@property(nonatomic, readonly, copy) NSString *cachePath;
- (void)invalidate;
@end

@interface AskaraCEFBridge : NSObject

@property(class, nonatomic, readonly, getter=isInitialized) BOOL initialized;
/// Creates the required CefAppProtocol-conforming singleton before any NSApplication.shared access.
@property(class, nonatomic, readonly) NSApplication *application;

/// Initializes the browser process. The app bundle must already contain the CEF framework and
/// Askara Helper app. Returns NO with an error instead of leaving Blink half-enabled.
+ (BOOL)initializeWithRootCachePath:(NSString *)rootCachePath
                              error:(NSError * _Nullable * _Nullable)error;

/// Invokes the block on the AppKit main thread after CefBrowserProcessHandler::OnContextInitialized.
+ (void)whenReady:(dispatch_block_t)block;

/// Creates one persistent Chromium request context for one Askara profile.
+ (nullable AskaraCEFRequestContext *)createRequestContextAtCachePath:(NSString *)cachePath
                                                                error:(NSError * _Nullable * _Nullable)error;

/// Pumps pending CEF work from AppKit's main run loop.
+ (void)doMessageLoopWork;

/// Called once during orderly application shutdown.
+ (void)shutdown;

@end

NS_ASSUME_NONNULL_END
