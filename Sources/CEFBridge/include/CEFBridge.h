#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// NSApplication must implement CefAppProtocol before CEF initializes on macOS. The bundled app
/// selects this class through NSPrincipalClass only when built with CEF.
@interface AskaraCEFApplication : NSApplication
@end

@interface AskaraCEFRequestContext : NSObject
@property(nonatomic, readonly, copy) NSString *cachePath;
/// Deletes all cookies and the HTTP cache of this context. The block runs on the main thread.
- (void)clearCookiesAndCache:(dispatch_block_t)completion;
- (void)invalidate;
@end

/// Native windowed CEF browser content. Callbacks execute on AppKit's main thread.
@interface AskaraCEFBrowserView : NSView
@property(nonatomic, readonly, nullable) NSURL *URL;
@property(nonatomic, readonly, copy) NSString *pageTitle;
@property(nonatomic, readonly, getter=isLoading) BOOL loading;
@property(nonatomic, readonly) double estimatedProgress;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;
@property(nonatomic, copy, nullable) dispatch_block_t onStateChanged;
@property(nonatomic, copy, nullable) dispatch_block_t onBrowserCreated;
@property(nonatomic, copy, nullable) dispatch_block_t onLoadCompleted;
@property(nonatomic, copy, nullable) void (^onLoadFailed)(NSString *message);
@property(nonatomic, copy, nullable) dispatch_block_t onClosed;
/// target=_blank / window.open. The popup itself is cancelled; the host opens the URL in a tab.
@property(nonatomic, copy, nullable) void (^onOpenURLInNewTab)(NSURL *URL);

- (instancetype)initWithFrame:(NSRect)frame
                requestContext:(AskaraCEFRequestContext *)requestContext NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
- (void)loadURL:(NSURL *)URL;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
/// 1 = 100%. Applied once the browser exists if called earlier.
- (void)setZoomFactor:(double)factor;
- (void)setAudioMuted:(BOOL)muted;
/// Closes the browser. Safe before creation finished; onClosed fires exactly once either way.
- (void)close;
@end

@interface AskaraCEFBridge : NSObject

@property(class, nonatomic, readonly, getter=isInitialized) BOOL initialized;
/// True after CefBrowserProcessHandler::OnContextInitialized.
@property(class, nonatomic, readonly, getter=isReady) BOOL ready;
/// Browsers being created or not yet fully closed. Zero once every tab released its browser.
@property(class, nonatomic, readonly) NSInteger liveBrowserCount;
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
