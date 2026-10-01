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

typedef NS_ENUM(NSInteger, AskaraCEFDownloadState) {
    AskaraCEFDownloadStateRunning,
    AskaraCEFDownloadStateComplete,
    AskaraCEFDownloadStateCancelled,
    AskaraCEFDownloadStateFailed,
};

/// Download operation independent of the tab that initiated it.
@interface AskaraCEFDownload : NSObject
@property(nonatomic, readonly, copy) NSString *identifier;
@property(nonatomic, readonly, nullable) NSURL *sourceURL;
@property(nonatomic, readonly, copy) NSString *suggestedFilename;
@property(nonatomic, readonly) int64_t receivedBytes;
@property(nonatomic, readonly) int64_t totalBytes;
/// 0...1 when known, or -1 for indeterminate progress.
@property(nonatomic, readonly) double fractionCompleted;
@property(nonatomic, readonly) AskaraCEFDownloadState state;
@property(nonatomic, readonly, nullable, copy) NSString *failureMessage;
@property(nonatomic, copy, nullable) dispatch_block_t onChanged;
- (void)cancel;
@end

typedef NS_OPTIONS(NSUInteger, AskaraCEFPermissionKind) {
    AskaraCEFPermissionKindCamera = 1 << 0,
    AskaraCEFPermissionKindMicrophone = 1 << 1,
    AskaraCEFPermissionKindLocation = 1 << 2,
};

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
/// Main-frame document committed. Used for site CSS/JavaScript injection.
@property(nonatomic, copy, nullable) void (^onMainFrameLoadStarted)(NSURL *URL);
@property(nonatomic, copy, nullable) dispatch_block_t onLoadCompleted;
@property(nonatomic, copy, nullable) void (^onLoadFailed)(NSURL * _Nullable URL,
                                                          NSInteger errorCode,
                                                          NSString *message);
/// HTTPS-Only could not load the secure URL, or it redirected back to HTTP.
@property(nonatomic, copy, nullable) void (^onHTTPSFallbackRequired)(NSURL *insecureURL,
                                                                     NSURL *secureURL,
                                                                     NSInteger errorCode,
                                                                     NSString *message);
@property(nonatomic, copy, nullable) dispatch_block_t onClosed;
/// target=_blank / window.open fallback when a scriptable popup cannot be adopted.
@property(nonatomic, copy, nullable) void (^onOpenURLInNewTab)(NSURL *URL);
/// Called synchronously for a user-gesture popup. Return YES after adopting the supplied view into
/// a visible tab; CEF then creates the popup browser in it and preserves window.opener.
@property(nonatomic, copy, nullable) BOOL (^onPopupRequested)(AskaraCEFBrowserView *popupView,
                                                              NSURL * _Nullable URL);
/// Return a full file URL to accept the download, or nil to cancel it.
@property(nonatomic, copy, nullable) NSURL * _Nullable (^onDownloadRequested)(AskaraCEFDownload *download);
@property(nonatomic, copy, nullable) void (^onPermissionRequested)(
    uint64_t requestID, NSURL *requestingOrigin, AskaraCEFPermissionKind kinds,
    void (^decisionHandler)(BOOL allowed));
@property(nonatomic, copy, nullable) void (^onPermissionRequestCancelled)(uint64_t requestID);

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
/// Replaces the native request-policy snapshot. Domain matching includes real subdomains only.
- (void)setBlockedDomains:(NSArray<NSString *> *)domains
            excludingSites:(NSArray<NSString *> *)excludingSites;
- (void)setJavaScriptBlockedDomains:(NSArray<NSString *> *)domains;
- (void)setHTTPSOnlyEnabled:(BOOL)enabled allowedHTTPHosts:(NSArray<NSString *> *)hosts;
/// Executes in the current main frame. CEF reports errors in the page console, not via a callback.
- (void)executeJavaScript:(NSString *)source sourceURL:(nullable NSURL *)sourceURL;
/// Test/automation input in view coordinates.
- (void)sendMouseClickAt:(NSPoint)point;
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
