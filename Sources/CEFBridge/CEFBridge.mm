#import "CEFBridge.h"

#include <crt_externs.h>
#include <mach-o/dyld.h>
#include <algorithm>
#include <atomic>
#include <cctype>
#include <climits>
#include <cmath>
#include <mutex>
#include <optional>
#include <unordered_set>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_callback.h"
#include "include/cef_command_line.h"
#include "include/cef_cookie.h"
#include "include/cef_display_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_download_item.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_parser.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_request_context.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

namespace {
constexpr NSInteger kCEFBridgeError = 1;
NSString *const kCEFBridgeErrorDomain = @"dev.adityadarma.askara.cef";

std::unique_ptr<CefScopedLibraryLoader> g_loader;
bool g_initialized = false;
bool g_ready = false;
NSMutableArray<dispatch_block_t> *g_ready_blocks;
// Browsers requested but not yet created, and browsers not yet closed. CefShutdown requires
// both to be zero, so shutdown closes every view and pumps until they drain.
int g_pending_browsers = 0;
int g_open_browsers = 0;
NSHashTable *g_views;
class AskaraCEFApp;
CefRefPtr<AskaraCEFApp> g_app;

NSString *NSStringFromCEF(const CefString& value);

void SetError(NSError **error, NSString *message) {
  if (!error) return;
  *error = [NSError errorWithDomain:kCEFBridgeErrorDomain
                               code:kCEFBridgeError
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

class AskaraCEFApp final : public CefApp, public CefBrowserProcessHandler {
 public:
  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    command_line->AppendSwitch("use-alloy-style");
  }

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  void OnContextInitialized() override {
    CEF_REQUIRE_UI_THREAD();
    g_ready = true;
    NSArray<dispatch_block_t> *blocks = [g_ready_blocks copy];
    [g_ready_blocks removeAllObjects];
    for (dispatch_block_t block in blocks) block();
  }

  void OnScheduleMessagePumpWork(int64_t delay_ms) override;

  IMPLEMENT_REFCOUNTING(AskaraCEFApp);
};

class AskaraCEFClient final : public CefClient,
                               public CefDisplayHandler,
                               public CefDownloadHandler,
                               public CefLifeSpanHandler,
                               public CefLoadHandler,
                               public CefPermissionHandler,
                               public CefRequestHandler,
                               public CefResourceRequestHandler {
 public:
  struct PendingHTTPSUpgrade {
    std::string insecure_url;
    std::string secure_url;
    std::string host;
  };

  explicit AskaraCEFClient(AskaraCEFBrowserView *view)
      : view_(view), downloads_([[NSMutableDictionary alloc] init]) {}

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                     const CefString& target_url, const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition, bool user_gesture,
                     const CefPopupFeatures& popupFeatures, CefWindowInfo& windowInfo,
                     CefRefPtr<CefClient>& client, CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popup_id) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       const CefString& url) override;
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override;
  void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) override;
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool is_loading,
                             bool can_go_back, bool can_go_forward) override;
  void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override;
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                 int http_status_code) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                    ErrorCode error_code, const CefString& error_text,
                    const CefString& failed_url) override;
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request, bool user_gesture,
                      bool is_redirect) override;
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request, bool is_navigation, bool is_download,
      const CefString& request_initiator, bool& disable_default_handling) override;
  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback> callback) override;
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> download_item,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override;
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override;
  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      const CefString& requesting_origin, uint32_t requested_permissions,
      CefRefPtr<CefMediaAccessCallback> callback) override;
  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser> browser, uint64_t prompt_id, const CefString& requesting_origin,
      uint32_t requested_permissions, CefRefPtr<CefPermissionPromptCallback> callback) override;
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt_id,
                                 cef_permission_request_result_t result) override;

  CefRefPtr<CefBrowser> browser() const { return browser_; }
  void SetInitialURL(const CefString& url) { initial_url_ = url; }
  void SetBlockedDomains(NSArray<NSString *> *domains, NSArray<NSString *> *exceptions);
  void SetJavaScriptBlockedDomains(NSArray<NSString *> *domains);
  void SetHTTPSOnly(bool enabled, NSArray<NSString *> *allowed_hosts);
  void ReportHTTPSFallback(const PendingHTTPSUpgrade& pending, ErrorCode code,
                           NSString *message);
  void PreparePopup(AskaraCEFBrowserView *opener_view, int popup_id);
  void PopupResolved(int popup_id);

 private:
  __weak AskaraCEFBrowserView *view_;
  CefRefPtr<CefBrowser> browser_;
  __strong NSMutableDictionary<NSNumber *, AskaraCEFDownload *> *downloads_;
  CefString initial_url_;
  std::mutex policy_mutex_;
  std::unordered_set<std::string> blocked_domains_;
  std::unordered_set<std::string> ad_block_exceptions_;
  std::unordered_set<std::string> javascript_blocked_domains_;
  std::unordered_set<std::string> allowed_http_hosts_;
  std::string top_level_host_;
  bool https_only_ = false;
  std::optional<PendingHTTPSUpgrade> pending_https_upgrade_;
  __weak AskaraCEFBrowserView *popup_opener_view_;
  int popup_id_ = 0;
  __strong NSMutableDictionary<NSNumber *, AskaraCEFBrowserView *> *pending_popups_ =
      [[NSMutableDictionary alloc] init];
  IMPLEMENT_REFCOUNTING(AskaraCEFClient);
};
}  // namespace

/// Port of CEF's MainMessageLoopExternalPumpMac (tests/shared/browser). Guards against
/// re-entrant CefDoMessageLoopWork, keeps a 30 fps heartbeat so work is never stranded when a
/// nested Cocoa loop swallows a callback, and fires in event-tracking mode too.
@interface AskaraCEFPump : NSObject
+ (AskaraCEFPump *)shared;
- (void)scheduleWork:(NSNumber *)delayMs;
- (void)start;
- (void)stop;
@end

@interface AskaraCEFPendingPermission : NSObject
@property(nonatomic) uint64_t requestID;
@property(nonatomic) uint64_t cefPromptID;
@property(nonatomic, copy) void (^answer)(BOOL allowed);
@property(nonatomic, copy) dispatch_block_t cancel;
@end
@implementation AskaraCEFPendingPermission
@end

@implementation AskaraCEFPump {
  NSTimer *_timer;
  BOOL _active;
  BOOL _reentrancyDetected;
  BOOL _stopped;
}

static const int64_t kAskaraTimerPlaceholder = INT_MAX;
static const int64_t kAskaraMaxTimerDelay = 1000 / 30;

+ (AskaraCEFPump *)shared {
  static AskaraCEFPump *pump;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ pump = [[AskaraCEFPump alloc] init]; });
  return pump;
}

- (void)scheduleWork:(NSNumber *)delayMs {
  if (_stopped || !g_initialized) return;
  int64_t delay = delayMs.longLongValue;
  if (delay == kAskaraTimerPlaceholder && _timer) return;
  [self killTimer];
  if (delay <= 0) {
    [self doWork];
  } else {
    [self setTimer:std::min(delay, kAskaraMaxTimerDelay)];
  }
}

- (void)timerFired:(NSTimer *)timer {
  [self killTimer];
  [self doWork];
}

- (void)doWork {
  if (_stopped || !g_initialized) return;
  if (_active) {
    _reentrancyDetected = YES;
    return;
  }
  _reentrancyDetected = NO;
  _active = YES;
  CefDoMessageLoopWork();
  _active = NO;
  if (_reentrancyDetected) {
    [self scheduleWork:@0];
  } else if (!_timer) {
    [self scheduleWork:@(kAskaraTimerPlaceholder)];
  }
}

- (void)setTimer:(int64_t)delayMs {
  _timer = [NSTimer timerWithTimeInterval:delayMs / 1000.0
                                   target:self
                                 selector:@selector(timerFired:)
                                 userInfo:nil
                                  repeats:NO];
  NSRunLoop *loop = [NSRunLoop mainRunLoop];
  [loop addTimer:_timer forMode:NSRunLoopCommonModes];
  [loop addTimer:_timer forMode:NSEventTrackingRunLoopMode];
}

- (void)killTimer {
  [_timer invalidate];
  _timer = nil;
}

- (void)start { _stopped = NO; }

- (void)stop {
  _stopped = YES;
  [self killTimer];
}
@end

namespace {
void AskaraCEFApp::OnScheduleMessagePumpWork(int64_t delay_ms) {
  // May be called on any thread; the pump always runs on the main thread.
  [[AskaraCEFPump shared] performSelectorOnMainThread:@selector(scheduleWork:)
                                           withObject:@(delay_ms)
                                        waitUntilDone:NO
                                                modes:@[ NSRunLoopCommonModes, NSEventTrackingRunLoopMode ]];
}
}  // namespace

@implementation AskaraCEFApplication {
  BOOL _handlingSendEvent;
}

- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)setHandlingSendEvent:(BOOL)value { _handlingSendEvent = value; }

- (void)sendEvent:(NSEvent *)event {
  if (g_initialized) {
    CefScopedSendingEvent scope;
    [super sendEvent:event];
  } else {
    [super sendEvent:event];
  }
}
@end

namespace {
class AskaraCEFDeleteCookies final : public CefDeleteCookiesCallback {
 public:
  explicit AskaraCEFDeleteCookies(dispatch_block_t done) : done_(done) {}
  void OnComplete(int num_deleted) override {
    dispatch_block_t done = done_;
    dispatch_async(dispatch_get_main_queue(), done);
  }
 private:
  dispatch_block_t done_;
  IMPLEMENT_REFCOUNTING(AskaraCEFDeleteCookies);
};

class AskaraCEFCompletion final : public CefCompletionCallback {
 public:
  explicit AskaraCEFCompletion(dispatch_block_t done) : done_(done) {}
  void OnComplete() override {
    dispatch_block_t done = done_;
    dispatch_async(dispatch_get_main_queue(), done);
  }
 private:
  dispatch_block_t done_;
  IMPLEMENT_REFCOUNTING(AskaraCEFCompletion);
};
}  // namespace

@interface AskaraCEFRequestContext () {
 @package
  CefRefPtr<CefRequestContext> _context;
  BOOL _invalidated;
}
@property(nonatomic, readwrite, copy) NSString *cachePath;
- (CefRefPtr<CefRequestContext>)cefContext;
@end

@implementation AskaraCEFRequestContext
/// Created on first use: CEF only accepts request contexts after OnContextInitialized.
- (CefRefPtr<CefRequestContext>)cefContext {
  if (!_context && !_invalidated && g_ready) {
    CefRequestContextSettings settings;
    CefString(&settings.cache_path) = self.cachePath.UTF8String;
    // An empty cache path is an in-memory (incognito) context; nothing can be persisted.
    settings.persist_session_cookies = self.cachePath.length > 0;
    _context = CefRequestContext::CreateContext(settings, nullptr);
  }
  return _context;
}
- (void)clearCookiesAndCache:(dispatch_block_t)completion {
  CefRefPtr<CefRequestContext> context = [self cefContext];
  if (!context) {
    dispatch_async(dispatch_get_main_queue(), completion);
    return;
  }
  // Both steps report on CEF's UI thread (the main thread); finish once both are done.
  __block int remaining = 2;
  dispatch_block_t done = ^{
    if (--remaining == 0) completion();
  };
  CefRefPtr<AskaraCEFDeleteCookies> cookies = new AskaraCEFDeleteCookies(done);
  CefRefPtr<CefCookieManager> manager = context->GetCookieManager(nullptr);
  if (!manager || !manager->DeleteCookies("", "", cookies)) done();
  context->ClearHttpCache(new AskaraCEFCompletion(done));
}

- (void)invalidate {
  _invalidated = YES;
  _context = nullptr;
}
- (void)dealloc { _context = nullptr; }
@end

@interface AskaraCEFDownload () {
 @package
  CefRefPtr<CefDownloadItemCallback> _callback;
  BOOL _hasSnapshot;
}
@property(nonatomic, readwrite, copy) NSString *identifier;
@property(nonatomic, readwrite, nullable) NSURL *sourceURL;
@property(nonatomic, readwrite, copy) NSString *suggestedFilename;
@property(nonatomic, readwrite) int64_t receivedBytes;
@property(nonatomic, readwrite) int64_t totalBytes;
@property(nonatomic, readwrite) double fractionCompleted;
@property(nonatomic, readwrite) AskaraCEFDownloadState state;
@property(nonatomic, readwrite, nullable, copy) NSString *failureMessage;
- (void)prepareFromItem:(CefRefPtr<CefDownloadItem>)item suggestedName:(NSString *)name;
- (void)updateFromItem:(CefRefPtr<CefDownloadItem>)item
              callback:(CefRefPtr<CefDownloadItemCallback>)callback;
@end

static NSString *DownloadInterruptMessage(cef_download_interrupt_reason_t reason) {
  switch (reason) {
    case CEF_DOWNLOAD_INTERRUPT_REASON_FILE_ACCESS_DENIED: return @"File access was denied";
    case CEF_DOWNLOAD_INTERRUPT_REASON_FILE_NO_SPACE: return @"There is not enough disk space";
    case CEF_DOWNLOAD_INTERRUPT_REASON_NETWORK_TIMEOUT: return @"The network request timed out";
    case CEF_DOWNLOAD_INTERRUPT_REASON_NETWORK_DISCONNECTED: return @"The network connection was lost";
    case CEF_DOWNLOAD_INTERRUPT_REASON_SERVER_FORBIDDEN: return @"The server denied the download";
    case CEF_DOWNLOAD_INTERRUPT_REASON_SERVER_UNAUTHORIZED: return @"The server requires authorization";
    case CEF_DOWNLOAD_INTERRUPT_REASON_SERVER_CONTENT_LENGTH_MISMATCH: return @"The server sent an incomplete file";
    case CEF_DOWNLOAD_INTERRUPT_REASON_CRASH: return @"The download process crashed";
    default:
      return [NSString stringWithFormat:@"Chromium interrupted the download (%ld)",
                                        static_cast<long>(reason)];
  }
}

@implementation AskaraCEFDownload
- (instancetype)init {
  self = [super init];
  if (self) {
    _identifier = NSUUID.UUID.UUIDString;
    _suggestedFilename = @"download";
    _fractionCompleted = -1;
    _state = AskaraCEFDownloadStateRunning;
  }
  return self;
}
- (void)setOnChanged:(dispatch_block_t)onChanged {
  _onChanged = [onChanged copy];
  if (_onChanged && _hasSnapshot) _onChanged();
}
- (void)prepareFromItem:(CefRefPtr<CefDownloadItem>)item suggestedName:(NSString *)name {
  self.suggestedFilename = name.length ? name : @"download";
  NSString *source = NSStringFromCEF(item->GetOriginalUrl());
  if (!source.length) source = NSStringFromCEF(item->GetURL());
  self.sourceURL = [NSURL URLWithString:source];
}
- (void)updateFromItem:(CefRefPtr<CefDownloadItem>)item
              callback:(CefRefPtr<CefDownloadItemCallback>)callback {
  _callback = callback;
  self.receivedBytes = item->GetReceivedBytes();
  self.totalBytes = item->GetTotalBytes();
  const int percent = item->GetPercentComplete();
  if (percent >= 0) {
    self.fractionCompleted = std::clamp(percent / 100.0, 0.0, 1.0);
  } else if (self.totalBytes > 0) {
    self.fractionCompleted = std::clamp(
        static_cast<double>(self.receivedBytes) / self.totalBytes, 0.0, 1.0);
  } else {
    self.fractionCompleted = -1;
  }
  if (item->IsComplete()) {
    self.state = AskaraCEFDownloadStateComplete;
  } else if (item->IsCanceled()) {
    self.state = AskaraCEFDownloadStateCancelled;
  } else if (item->IsInterrupted()) {
    self.state = AskaraCEFDownloadStateFailed;
    self.failureMessage = DownloadInterruptMessage(item->GetInterruptReason());
  } else {
    self.state = AskaraCEFDownloadStateRunning;
  }
  const BOOL terminal = self.state != AskaraCEFDownloadStateRunning;
  _hasSnapshot = YES;
  if (self.onChanged) self.onChanged();
  if (terminal) _callback = nullptr;
}
- (void)cancel {
  if (self.state == AskaraCEFDownloadStateRunning && _callback) _callback->Cancel();
}
@end

@interface AskaraCEFBrowserView () {
 @package
  CefRefPtr<AskaraCEFClient> _client;
  AskaraCEFRequestContext *_contextWrapper;
  CefRefPtr<CefRequestContext> _requestContext;
  NSURL *_pendingURL;
  BOOL _browserCreationRequested;
  BOOL _waitingForReady;
  BOOL _closeRequested;
  BOOL _closedReported;
  double _zoomFactor;
  BOOL _muted;
  uint64_t _nextPermissionRequestID;
  NSMutableDictionary<NSNumber *, AskaraCEFPendingPermission *> *_pendingPermissions;
  NSMutableDictionary<NSNumber *, NSNumber *> *_permissionRequestByCEFPromptID;
}
@property(nonatomic, readwrite, nullable) NSURL *URL;
@property(nonatomic, readwrite, copy) NSString *pageTitle;
@property(nonatomic, readwrite, getter=isLoading) BOOL loading;
@property(nonatomic, readwrite) double estimatedProgress;
@property(nonatomic, readwrite) BOOL canGoBack;
@property(nonatomic, readwrite) BOOL canGoForward;
- (void)browserCreated;
- (void)browserClosed;
- (void)createBrowserIfPossible;
- (void)createBrowserOnCEFUIThread;
- (void)requestPermissionForOrigin:(NSURL *)origin
                             kinds:(AskaraCEFPermissionKind)kinds
                       cefPromptID:(uint64_t)cefPromptID
                            answer:(void (^)(BOOL allowed))answer
                            cancel:(dispatch_block_t)cancel;
- (void)cancelAllPermissionRequests;
- (void)cefDismissedPermissionPrompt:(uint64_t)cefPromptID;
- (void)prepareForPopup;
- (void)popupCreationAborted;
@end

@implementation AskaraCEFBrowserView

- (instancetype)initWithFrame:(NSRect)frame requestContext:(AskaraCEFRequestContext *)requestContext {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.wantsLayer = YES;
  self.pageTitle = @"";
  _estimatedProgress = 0;
  _zoomFactor = 1;
  _nextPermissionRequestID = 1;
  _pendingPermissions = [[NSMutableDictionary alloc] init];
  _permissionRequestByCEFPromptID = [[NSMutableDictionary alloc] init];
  _client = new AskaraCEFClient(self);
  _contextWrapper = requestContext;
  if (!g_views) g_views = [NSHashTable weakObjectsHashTable];
  [g_views addObject:self];
  return self;
}

- (BOOL)isFlipped { return YES; }

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  CefRefPtr<CefBrowser> browser = _client ? _client->browser() : nullptr;
  // Background tabs are detached from the window: let Chromium throttle them.
  if (browser) browser->GetHost()->WasHidden(self.window == nil);
  if (!self.window) [self cancelAllPermissionRequests];
  [self createBrowserIfPossible];
}

/// Native child browsers need a window, and CEF needs OnContextInitialized first.
- (void)createBrowserIfPossible {
  if (!self.window || _browserCreationRequested || _closeRequested || !_client) return;
  if (!g_ready) {
    if (_waitingForReady) return;
    _waitingForReady = YES;
    __weak AskaraCEFBrowserView *weakSelf = self;
    [AskaraCEFBridge whenReady:^{
      AskaraCEFBrowserView *view = weakSelf;
      if (!view) return;
      view->_waitingForReady = NO;
      [view createBrowserIfPossible];
    }];
    return;
  }
  _browserCreationRequested = YES;
  [self createBrowserOnCEFUIThread];
}

- (void)createBrowserOnCEFUIThread {
  CEF_REQUIRE_UI_THREAD();
  _requestContext = [_contextWrapper cefContext];
  if (!_client || !_requestContext || !self.window) {
    _browserCreationRequested = NO;
    if (self.onLoadFailed) self.onLoadFailed(nil, 0, @"CEF browser prerequisites are missing");
    return;
  }
  CefWindowInfo window_info;
  CefRect bounds(0, 0, std::max(1, static_cast<int>(self.bounds.size.width)),
                 std::max(1, static_cast<int>(self.bounds.size.height)));
  window_info.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(self), bounds);
  window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  const CefString initial_url = _pendingURL ? _pendingURL.absoluteString.UTF8String : "about:blank";
  _pendingURL = nil;
  _client->SetInitialURL(initial_url);
  if (CefBrowserHost::CreateBrowser(window_info, _client, "about:blank", settings, nullptr,
                                    _requestContext)) {
    ++g_pending_browsers;
  } else {
    _browserCreationRequested = NO;
    NSString *message = [NSString stringWithFormat:
        @"CEF browser creation request failed (ui=%d window=%d bounds=%dx%d)",
        CefCurrentlyOn(TID_UI), self.window != nil, bounds.width, bounds.height];
    if (self.onLoadFailed) self.onLoadFailed(nil, 0, message);
  }
}

- (void)prepareForPopup {
  _browserCreationRequested = YES;
  ++g_pending_browsers;
}

- (void)popupCreationAborted {
  if (_browserCreationRequested) {
    _browserCreationRequested = NO;
    --g_pending_browsers;
  }
  [self browserClosed];
}

- (void)layout {
  [super layout];
  CefRefPtr<CefBrowser> browser = _client ? _client->browser() : nullptr;
  if (!browser) return;
  NSView *child = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  child.frame = self.bounds;
  browser->GetHost()->WasResized();
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder {
  CefRefPtr<CefBrowser> browser = _client ? _client->browser() : nullptr;
  if (browser) browser->GetHost()->SetFocus(true);
  return [super becomeFirstResponder];
}

- (void)loadURL:(NSURL *)URL {
  CefRefPtr<CefBrowser> browser = _client ? _client->browser() : nullptr;
  if (browser) {
    browser->GetMainFrame()->LoadURL(URL.absoluteString.UTF8String);
  } else {
    _pendingURL = URL;
  }
}
- (void)goBack { if (_client && _client->browser()) _client->browser()->GoBack(); }
- (void)goForward { if (_client && _client->browser()) _client->browser()->GoForward(); }
- (void)reload { if (_client && _client->browser()) _client->browser()->Reload(); }
- (void)stopLoading { if (_client && _client->browser()) _client->browser()->StopLoad(); }

// Chromium zoom levels are logarithmic: factor = 1.2 ^ level.
static double ZoomLevelForFactor(double factor) {
  return factor > 0 ? std::log(factor) / std::log(1.2) : 0;
}

- (void)setZoomFactor:(double)factor {
  _zoomFactor = factor;
  if (_client && _client->browser()) _client->browser()->GetHost()->SetZoomLevel(ZoomLevelForFactor(factor));
}

- (void)setAudioMuted:(BOOL)muted {
  _muted = muted;
  if (_client && _client->browser()) _client->browser()->GetHost()->SetAudioMuted(muted);
}

- (void)setBlockedDomains:(NSArray<NSString *> *)domains excludingSites:(NSArray<NSString *> *)sites {
  if (_client) _client->SetBlockedDomains(domains, sites);
}

- (void)setJavaScriptBlockedDomains:(NSArray<NSString *> *)domains {
  if (_client) _client->SetJavaScriptBlockedDomains(domains);
}

- (void)setHTTPSOnlyEnabled:(BOOL)enabled allowedHTTPHosts:(NSArray<NSString *> *)hosts {
  if (_client) _client->SetHTTPSOnly(enabled, hosts);
}

- (void)executeJavaScript:(NSString *)source sourceURL:(NSURL *)sourceURL {
  CefRefPtr<CefBrowser> browser = _client ? _client->browser() : nullptr;
  if (!browser) return;
  CefRefPtr<CefFrame> frame = browser->GetMainFrame();
  if (!frame || !frame->IsValid()) return;
  const char *url = sourceURL ? sourceURL.absoluteString.UTF8String
                              : "askara://site-customization";
  frame->ExecuteJavaScript(source.UTF8String, url, 1);
}

- (void)sendMouseClickAt:(NSPoint)point {
  CefRefPtr<CefBrowser> browser = _client ? _client->browser() : nullptr;
  if (!browser) return;
  CefMouseEvent event;
  event.x = static_cast<int>(point.x);
  event.y = static_cast<int>(point.y);
  browser->GetHost()->SendMouseClickEvent(event, MBT_LEFT, false, 1);
  browser->GetHost()->SendMouseClickEvent(event, MBT_LEFT, true, 1);
}

- (void)close {
  if (_closeRequested) return;
  [self cancelAllPermissionRequests];
  _closeRequested = YES;
  if (_client && _client->browser()) {
    _client->browser()->GetHost()->CloseBrowser(true);
  } else if (!_browserCreationRequested) {
    // Never attached to a window, so no browser will ever exist: finish the close now.
    dispatch_async(dispatch_get_main_queue(), ^{ [self browserClosed]; });
  }
  // Otherwise creation is in flight; browserCreated closes it as soon as it exists.
}

- (void)browserCreated {
  if (_closeRequested) {
    _client->browser()->GetHost()->CloseBrowser(true);
    return;
  }
  CefRefPtr<CefBrowserHost> host = _client->browser()->GetHost();
  if (_zoomFactor != 1) host->SetZoomLevel(ZoomLevelForFactor(_zoomFactor));
  if (_muted) host->SetAudioMuted(true);
  [self setNeedsLayout:YES];
  if (self.onBrowserCreated) self.onBrowserCreated();
  if (self.onStateChanged) self.onStateChanged();
}
- (void)browserClosed {
  if (_closedReported) return;
  _closedReported = YES;
  [self cancelAllPermissionRequests];
  _client = nullptr;
  _requestContext = nullptr;
  // Hold the block locally: the handler may release this view (and its blocks) while running.
  dispatch_block_t onClosed = self.onClosed;
  self.onClosed = nil;
  if (onClosed) onClosed();
}
- (void)dealloc {
  [self cancelAllPermissionRequests];
  if (_client && _client->browser()) _client->browser()->GetHost()->CloseBrowser(true);
}

- (void)requestPermissionForOrigin:(NSURL *)origin
                             kinds:(AskaraCEFPermissionKind)kinds
                       cefPromptID:(uint64_t)cefPromptID
                            answer:(void (^)(BOOL allowed))answer
                            cancel:(dispatch_block_t)cancel {
  const uint64_t requestID = _nextPermissionRequestID++;
  AskaraCEFPendingPermission *pending = [[AskaraCEFPendingPermission alloc] init];
  pending.requestID = requestID;
  pending.cefPromptID = cefPromptID;
  pending.answer = answer;
  pending.cancel = cancel;
  _pendingPermissions[@(requestID)] = pending;
  if (cefPromptID) _permissionRequestByCEFPromptID[@(cefPromptID)] = @(requestID);
  __weak AskaraCEFBrowserView *weakSelf = self;
  void (^decision)(BOOL) = ^(BOOL allowed) {
    AskaraCEFBrowserView *view = weakSelf;
    AskaraCEFPendingPermission *current = view->_pendingPermissions[@(requestID)];
    if (!current) return;
    [view->_pendingPermissions removeObjectForKey:@(requestID)];
    if (current.cefPromptID) {
      [view->_permissionRequestByCEFPromptID removeObjectForKey:@(current.cefPromptID)];
    }
    current.answer(allowed);
  };
  if (self.onPermissionRequested) {
    self.onPermissionRequested(requestID, origin, kinds, decision);
  } else {
    decision(NO);
  }
}

- (void)cancelAllPermissionRequests {
  NSArray<AskaraCEFPendingPermission *> *pending = _pendingPermissions.allValues;
  [_pendingPermissions removeAllObjects];
  [_permissionRequestByCEFPromptID removeAllObjects];
  for (AskaraCEFPendingPermission *request in pending) {
    request.cancel();
    if (self.onPermissionRequestCancelled) self.onPermissionRequestCancelled(request.requestID);
  }
}

- (void)cefDismissedPermissionPrompt:(uint64_t)cefPromptID {
  NSNumber *requestID = _permissionRequestByCEFPromptID[@(cefPromptID)];
  if (!requestID) return;
  AskaraCEFPendingPermission *pending = _pendingPermissions[requestID];
  [_permissionRequestByCEFPromptID removeObjectForKey:@(cefPromptID)];
  [_pendingPermissions removeObjectForKey:requestID];
  if (pending && self.onPermissionRequestCancelled) {
    self.onPermissionRequestCancelled(pending.requestID);
  }
}
@end

namespace {
NSString *NSStringFromCEF(const CefString& value) {
  const std::string utf8 = value.ToString();
  return [[NSString alloc] initWithBytes:utf8.data() length:utf8.size() encoding:NSUTF8StringEncoding] ?: @"";
}

std::string LowerASCII(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  if (!value.empty() && value.back() == '.') value.pop_back();
  return value;
}

std::string URLPart(const cef_string_t& part) { return CefString(&part).ToString(); }

bool ParseHTTPURL(const CefString& url, CefURLParts& parts, std::string& scheme, std::string& host) {
  if (!CefParseURL(url, parts)) return false;
  scheme = LowerASCII(URLPart(parts.scheme));
  host = LowerASCII(URLPart(parts.host));
  return (scheme == "http" || scheme == "https") && !host.empty();
}

bool MatchesDomain(const std::unordered_set<std::string>& domains, const std::string& host) {
  std::string candidate = host;
  while (!candidate.empty()) {
    if (domains.contains(candidate)) return true;
    const size_t dot = candidate.find('.');
    if (dot == std::string::npos) break;
    candidate.erase(0, dot + 1);
  }
  return false;
}

bool HostsRelated(const std::string& a, const std::string& b) {
  if (a == b) return true;
  return a.size() > b.size() && a.ends_with("." + b)
      || b.size() > a.size() && b.ends_with("." + a);
}

bool IsPublicHost(const std::string& host) {
  if (host.find('.') == std::string::npos || host.find(':') != std::string::npos) return false;
  bool ipv4 = true;
  for (char c : host) if (c != '.' && !std::isdigit(static_cast<unsigned char>(c))) ipv4 = false;
  if (ipv4) return false;
  static const char *suffixes[] = {
      ".local", ".localhost", ".internal", ".lan", ".home.arpa", ".test", ".invalid"};
  for (const char *suffix : suffixes) if (host.ends_with(suffix)) return false;
  return true;
}

std::unordered_set<std::string> DomainSet(NSArray<NSString *> *values) {
  std::unordered_set<std::string> result;
  result.reserve(values.count);
  for (NSString *value in values) result.insert(LowerASCII(value.UTF8String ?: ""));
  result.erase("");
  return result;
}

void AskaraCEFClient::SetBlockedDomains(NSArray<NSString *> *domains,
                                        NSArray<NSString *> *exceptions) {
  std::lock_guard lock(policy_mutex_);
  blocked_domains_ = DomainSet(domains);
  ad_block_exceptions_ = DomainSet(exceptions);
}

void AskaraCEFClient::SetJavaScriptBlockedDomains(NSArray<NSString *> *domains) {
  bool blocked = false;
  std::string url;
  {
    std::lock_guard lock(policy_mutex_);
    javascript_blocked_domains_ = DomainSet(domains);
    if (browser_ && browser_->GetMainFrame()) {
      url = browser_->GetMainFrame()->GetURL().ToString();
      CefURLParts parts;
      std::string scheme, host;
      if (ParseHTTPURL(url, parts, scheme, host)) {
        blocked = MatchesDomain(javascript_blocked_domains_, host);
      }
    }
  }
  if (!url.empty() && browser_) {
    CefRefPtr<CefRequestContext> context = browser_->GetHost()->GetRequestContext();
    context->SetContentSetting(url, url, CEF_CONTENT_SETTING_TYPE_JAVASCRIPT,
                               blocked ? CEF_CONTENT_SETTING_VALUE_BLOCK
                                       : CEF_CONTENT_SETTING_VALUE_ALLOW);
  }
}

void AskaraCEFClient::SetHTTPSOnly(bool enabled, NSArray<NSString *> *allowed_hosts) {
  std::lock_guard lock(policy_mutex_);
  https_only_ = enabled;
  allowed_http_hosts_ = DomainSet(allowed_hosts);
}

bool AskaraCEFClient::OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                     CefRefPtr<CefRequest> request, bool user_gesture,
                                     bool is_redirect) {
  CEF_REQUIRE_UI_THREAD();
  if (!frame->IsMain()) return false;
  [view_ cancelAllPermissionRequests];
  CefURLParts parts;
  std::string scheme, host;
  if (!ParseHTTPURL(request->GetURL(), parts, scheme, host)) {
    std::lock_guard lock(policy_mutex_);
    top_level_host_.clear();
    pending_https_upgrade_.reset();
    return false;
  }
  bool javascript_blocked;
  {
    std::lock_guard lock(policy_mutex_);
    top_level_host_ = host;
    javascript_blocked = MatchesDomain(javascript_blocked_domains_, host);
  }
  CefRefPtr<CefRequestContext> context = browser->GetHost()->GetRequestContext();
  context->SetContentSetting(request->GetURL(), request->GetURL(),
                             CEF_CONTENT_SETTING_TYPE_JAVASCRIPT,
                             javascript_blocked ? CEF_CONTENT_SETTING_VALUE_BLOCK
                                                : CEF_CONTENT_SETTING_VALUE_ALLOW);
  if (scheme == "http") {
    CefString(&parts.scheme) = "https";
    if (URLPart(parts.port) == "80") CefString(&parts.port).clear();
    CefString secure_url;
    if (CefCreateURL(parts, secure_url)) {
      context->SetContentSetting(secure_url, secure_url, CEF_CONTENT_SETTING_TYPE_JAVASCRIPT,
                                 javascript_blocked ? CEF_CONTENT_SETTING_VALUE_BLOCK
                                                    : CEF_CONTENT_SETTING_VALUE_ALLOW);
    }
  }
  return false;
}

void AskaraCEFClient::ReportHTTPSFallback(const PendingHTTPSUpgrade& pending, ErrorCode code,
                                          NSString *message) {
  CEF_REQUIRE_UI_THREAD();
  AskaraCEFBrowserView *view = view_;
  if (!view || !view.onHTTPSFallbackRequired) return;
  NSURL *insecure = [NSURL URLWithString:
      [NSString stringWithUTF8String:pending.insecure_url.c_str()]];
  NSURL *secure = [NSURL URLWithString:
      [NSString stringWithUTF8String:pending.secure_url.c_str()]];
  if (insecure && secure) view.onHTTPSFallbackRequired(insecure, secure, code, message);
}

CefRefPtr<CefResourceRequestHandler> AskaraCEFClient::GetResourceRequestHandler(
    CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
    bool is_navigation, bool is_download, const CefString& request_initiator,
    bool& disable_default_handling) {
  disable_default_handling = false;
  return this;
}

CefResourceRequestHandler::ReturnValue AskaraCEFClient::OnBeforeResourceLoad(
    CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
    CefRefPtr<CefCallback> callback) {
  CEF_REQUIRE_IO_THREAD();
  CefURLParts parts;
  std::string scheme, host;
  if (!ParseHTTPURL(request->GetURL(), parts, scheme, host)) return RV_CONTINUE;

  std::string top_host;
  bool https_only;
  bool should_upgrade = false;
  bool should_block = false;
  std::optional<PendingHTTPSUpgrade> pending;
  {
    std::lock_guard lock(policy_mutex_);
    top_host = top_level_host_;
    https_only = https_only_;
    should_upgrade = request->GetResourceType() == RT_MAIN_FRAME && scheme == "http"
        && https_only && IsPublicHost(host) && !MatchesDomain(allowed_http_hosts_, host);
    if (should_upgrade) pending = pending_https_upgrade_;
    should_block = request->GetResourceType() != RT_MAIN_FRAME && !top_host.empty()
        && !HostsRelated(host, top_host) && !MatchesDomain(ad_block_exceptions_, top_host)
        && MatchesDomain(blocked_domains_, host);
  }

  if (should_upgrade) {
    if (pending && pending->host == host) {
      {
        std::lock_guard lock(policy_mutex_);
        pending_https_upgrade_.reset();
      }
      CefRefPtr<AskaraCEFClient> client = this;
      const PendingHTTPSUpgrade upgrade = *pending;
      dispatch_async(dispatch_get_main_queue(), ^{
        client->ReportHTTPSFallback(upgrade, ERR_TOO_MANY_REDIRECTS,
                                    @"The secure page redirected back to HTTP");
      });
      return RV_CANCEL;
    }
    const std::string insecure_url = request->GetURL().ToString();
    CefString(&parts.scheme) = "https";
    if (URLPart(parts.port) == "80") CefString(&parts.port).clear();
    CefString secure_url;
    if (CefCreateURL(parts, secure_url)) {
      request->SetURL(secure_url);
      std::lock_guard lock(policy_mutex_);
      pending_https_upgrade_ = PendingHTTPSUpgrade{insecure_url, secure_url.ToString(), host};
    }
  }

  if (should_block) return RV_CANCEL;
  return RV_CONTINUE;
}

AskaraCEFDownload *DownloadFor(NSMutableDictionary<NSNumber *, AskaraCEFDownload *> *downloads,
                               CefRefPtr<CefDownloadItem> item) {
  NSNumber *key = @(item->GetId());
  AskaraCEFDownload *download = downloads[key];
  if (!download) {
    download = [[AskaraCEFDownload alloc] init];
    downloads[key] = download;
  }
  return download;
}

bool AskaraCEFClient::OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                                       CefRefPtr<CefDownloadItem> download_item,
                                       const CefString& suggested_name,
                                       CefRefPtr<CefBeforeDownloadCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  AskaraCEFDownload *download = DownloadFor(downloads_, download_item);
  [download prepareFromItem:download_item suggestedName:NSStringFromCEF(suggested_name)];
  AskaraCEFBrowserView *view = view_;
  if (!view || !view.onDownloadRequested) return true;
  NSURL *destination = view.onDownloadRequested(download);
  if (destination.isFileURL) callback->Continue(destination.path.UTF8String, false);
  return true;
}

void AskaraCEFClient::OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                                        CefRefPtr<CefDownloadItem> download_item,
                                        CefRefPtr<CefDownloadItemCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  NSNumber *key = @(download_item->GetId());
  AskaraCEFDownload *download = DownloadFor(downloads_, download_item);
  [download updateFromItem:download_item callback:callback];
  if (download_item->IsComplete() || download_item->IsCanceled() || download_item->IsInterrupted()) {
    [downloads_ removeObjectForKey:key];
  }
}

bool AskaraCEFClient::OnRequestMediaAccessPermission(
    CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
    const CefString& requesting_origin, uint32_t requested_permissions,
    CefRefPtr<CefMediaAccessCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  constexpr uint32_t supported = CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE
      | CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE;
  if (!view_ || requested_permissions == CEF_MEDIA_PERMISSION_NONE
      || (requested_permissions & ~supported) != 0) {
    callback->Continue(CEF_MEDIA_PERMISSION_NONE);
    return true;
  }
  AskaraCEFPermissionKind kinds = 0;
  if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE)
    kinds |= AskaraCEFPermissionKindCamera;
  if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE)
    kinds |= AskaraCEFPermissionKindMicrophone;
  NSURL *origin = [NSURL URLWithString:NSStringFromCEF(requesting_origin)];
  if (!origin.host.length) {
    callback->Continue(CEF_MEDIA_PERMISSION_NONE);
    return true;
  }
  [view_ requestPermissionForOrigin:origin kinds:kinds cefPromptID:0 answer:^(BOOL allowed) {
    callback->Continue(allowed ? requested_permissions : CEF_MEDIA_PERMISSION_NONE);
  } cancel:^{ callback->Cancel(); }];
  return true;
}

bool AskaraCEFClient::OnShowPermissionPrompt(
    CefRefPtr<CefBrowser> browser, uint64_t prompt_id, const CefString& requesting_origin,
    uint32_t requested_permissions, CefRefPtr<CefPermissionPromptCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  constexpr uint32_t supported = CEF_PERMISSION_TYPE_CAMERA_STREAM
      | CEF_PERMISSION_TYPE_MIC_STREAM | CEF_PERMISSION_TYPE_GEOLOCATION;
  if (!view_ || requested_permissions == CEF_PERMISSION_TYPE_NONE
      || (requested_permissions & ~supported) != 0) {
    callback->Continue(CEF_PERMISSION_RESULT_DENY);
    return true;
  }
  AskaraCEFPermissionKind kinds = 0;
  if (requested_permissions & CEF_PERMISSION_TYPE_CAMERA_STREAM)
    kinds |= AskaraCEFPermissionKindCamera;
  if (requested_permissions & CEF_PERMISSION_TYPE_MIC_STREAM)
    kinds |= AskaraCEFPermissionKindMicrophone;
  if (requested_permissions & CEF_PERMISSION_TYPE_GEOLOCATION)
    kinds |= AskaraCEFPermissionKindLocation;
  NSURL *origin = [NSURL URLWithString:NSStringFromCEF(requesting_origin)];
  if (!origin.host.length) {
    callback->Continue(CEF_PERMISSION_RESULT_DENY);
    return true;
  }
  [view_ requestPermissionForOrigin:origin kinds:kinds cefPromptID:prompt_id answer:^(BOOL allowed) {
    callback->Continue(allowed ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
  } cancel:^{ callback->Continue(CEF_PERMISSION_RESULT_DISMISS); }];
  return true;
}

void AskaraCEFClient::OnDismissPermissionPrompt(
    CefRefPtr<CefBrowser> browser, uint64_t prompt_id,
    cef_permission_request_result_t result) {
  CEF_REQUIRE_UI_THREAD();
  [view_ cefDismissedPermissionPrompt:prompt_id];
}

void AskaraCEFClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  --g_pending_browsers;
  ++g_open_browsers;
  browser_ = browser;
  AskaraCEFBrowserView *opener = popup_opener_view_;
  if (opener && opener->_client) opener->_client->PopupResolved(popup_id_);
  popup_opener_view_ = nil;
  popup_id_ = 0;
  if (!view_) {
    // The owning view went away while creation was in flight: never leak the browser.
    browser->GetHost()->CloseBrowser(true);
    return;
  }
  [view_ browserCreated];
  if (!initial_url_.empty()) {
    browser->GetMainFrame()->LoadURL(initial_url_);
    initial_url_.clear();
  }
}

bool AskaraCEFClient::OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                    int popup_id, const CefString& target_url,
                                    const CefString& target_frame_name,
                                    WindowOpenDisposition target_disposition, bool user_gesture,
                                    const CefPopupFeatures& popupFeatures,
                                    CefWindowInfo& windowInfo, CefRefPtr<CefClient>& client,
                                    CefBrowserSettings& settings,
                                    CefRefPtr<CefDictionaryValue>& extra_info,
                                    bool* no_javascript_access) {
  CEF_REQUIRE_UI_THREAD();
  if (!user_gesture || !view_) return true;
  NSURL *url = [NSURL URLWithString:NSStringFromCEF(target_url)];
  AskaraCEFBrowserView *popup = [[AskaraCEFBrowserView alloc]
      initWithFrame:view_.bounds requestContext:view_->_contextWrapper];
  [popup prepareForPopup];
  if (!popup || !view_.onPopupRequested || !view_.onPopupRequested(popup, url)
      || !popup.window) {
    [popup popupCreationAborted];
    if (url && view_.onOpenURLInNewTab) view_.onOpenURLInNewTab(url);
    return true;
  }
  CefRect bounds(0, 0, std::max(1, static_cast<int>(popup.bounds.size.width)),
                 std::max(1, static_cast<int>(popup.bounds.size.height)));
  windowInfo.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(popup), bounds);
  windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefRefPtr<AskaraCEFClient> popup_client = popup->_client;
  popup_client->PreparePopup(view_, popup_id);
  pending_popups_[@(popup_id)] = popup;
  client = popup_client;
  *no_javascript_access = false;
  return false;
}

void AskaraCEFClient::PreparePopup(AskaraCEFBrowserView *opener_view, int popup_id) {
  popup_opener_view_ = opener_view;
  popup_id_ = popup_id;
}

void AskaraCEFClient::PopupResolved(int popup_id) {
  [pending_popups_ removeObjectForKey:@(popup_id)];
}

void AskaraCEFClient::OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popup_id) {
  CEF_REQUIRE_UI_THREAD();
  AskaraCEFBrowserView *popup = pending_popups_[@(popup_id)];
  [pending_popups_ removeObjectForKey:@(popup_id)];
  [popup popupCreationAborted];
}

bool AskaraCEFClient::DoClose(CefRefPtr<CefBrowser> browser) {
  // Default Alloy behaviour sends performClose: to the top-level NSWindow. A browser window
  // hosts many tabs, so closing one tab must never close the window. Instead complete the
  // close by tearing down the browser's own child view, which leads to OnBeforeClose.
  NSView *child = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
  dispatch_async(dispatch_get_main_queue(), ^{ [child removeFromSuperview]; });
  return true;
}

void AskaraCEFClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  --g_open_browsers;
  browser_ = nullptr;
  popup_opener_view_ = nil;
  popup_id_ = 0;
  for (AskaraCEFBrowserView *popup in pending_popups_.allValues) [popup close];
  [pending_popups_ removeAllObjects];
  [downloads_ removeAllObjects];
  [view_ browserClosed];
  view_ = nil;
}

void AskaraCEFClient::OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                      const CefString& url) {
  if (!frame->IsMain() || !view_) return;
  view_.URL = [NSURL URLWithString:NSStringFromCEF(url)];
  if (view_.onStateChanged) view_.onStateChanged();
}

void AskaraCEFClient::OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) {
  if (!view_) return;
  view_.pageTitle = NSStringFromCEF(title);
  if (view_.onStateChanged) view_.onStateChanged();
}

void AskaraCEFClient::OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) {
  if (!view_) return;
  view_.estimatedProgress = progress;
  if (view_.onStateChanged) view_.onStateChanged();
}

void AskaraCEFClient::OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool is_loading,
                                           bool can_go_back, bool can_go_forward) {
  if (!view_) return;
  view_.loading = is_loading;
  view_.canGoBack = can_go_back;
  view_.canGoForward = can_go_forward;
  if (view_.onStateChanged) view_.onStateChanged();
}

void AskaraCEFClient::OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                  TransitionType transition_type) {
  if (!frame->IsMain() || !view_ || !view_.onMainFrameLoadStarted) return;
  NSURL *url = [NSURL URLWithString:NSStringFromCEF(frame->GetURL())];
  if (url) view_.onMainFrameLoadStarted(url);
}

void AskaraCEFClient::OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                 int http_status_code) {
  if (!frame->IsMain()) return;
  {
    std::lock_guard lock(policy_mutex_);
    pending_https_upgrade_.reset();
  }
  if (view_ && view_.onLoadCompleted) view_.onLoadCompleted();
}

void AskaraCEFClient::OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                  ErrorCode error_code, const CefString& error_text,
                                  const CefString& failed_url) {
  if (frame->IsMain() && view_ && error_code != ERR_ABORTED && view_.onLoadFailed) {
    NSURL *failed = [NSURL URLWithString:NSStringFromCEF(failed_url)];
    std::optional<PendingHTTPSUpgrade> pending;
    {
      std::lock_guard lock(policy_mutex_);
      if (pending_https_upgrade_ && pending_https_upgrade_->secure_url == failed_url.ToString()) {
        pending = pending_https_upgrade_;
        pending_https_upgrade_.reset();
      }
    }
    if (pending && view_.onHTTPSFallbackRequired) {
      NSURL *insecure = [NSURL URLWithString:
          [NSString stringWithUTF8String:pending->insecure_url.c_str()]];
      NSURL *secure = [NSURL URLWithString:
          [NSString stringWithUTF8String:pending->secure_url.c_str()]];
      if (insecure && secure) {
        view_.onHTTPSFallbackRequired(insecure, secure, error_code, NSStringFromCEF(error_text));
        return;
      }
    }
    view_.onLoadFailed(failed, error_code, NSStringFromCEF(error_text));
  }
}
}  // namespace

@implementation AskaraCEFBridge

+ (NSApplication *)application { return [AskaraCEFApplication sharedApplication]; }

+ (BOOL)isInitialized { return g_initialized; }
+ (BOOL)isReady { return g_ready; }
+ (NSInteger)liveBrowserCount { return g_open_browsers + g_pending_browsers; }

+ (void)whenReady:(dispatch_block_t)block {
  if (g_ready) {
    block();
  } else {
    if (!g_ready_blocks) g_ready_blocks = [[NSMutableArray alloc] init];
    [g_ready_blocks addObject:[block copy]];
  }
}

+ (BOOL)initializeWithRootCachePath:(NSString *)rootCachePath error:(NSError **)error {
  if (g_initialized) return YES;
  if (![NSApp isKindOfClass:[AskaraCEFApplication class]]) {
    SetError(error, @"NSPrincipalClass is not AskaraCEFApplication");
    return NO;
  }

  g_loader = std::make_unique<CefScopedLibraryLoader>();
  if (!g_loader->LoadInMain()) {
    g_loader.reset();
    SetError(error, @"Chromium Embedded Framework could not be loaded from the app bundle");
    return NO;
  }

  int argc = *_NSGetArgc();
  char **argv = *_NSGetArgv();
  CefMainArgs args(argc, argv);
  CefSettings settings;
  settings.no_sandbox = true;
  settings.external_message_pump = true;
  settings.persist_session_cookies = true;
  settings.log_severity = LOGSEVERITY_DISABLE;
  CefString(&settings.root_cache_path) = rootCachePath.UTF8String;
  NSString *helper = [[NSBundle mainBundle].bundlePath
      stringByAppendingPathComponent:@"Contents/Frameworks/Askara Helper.app/Contents/MacOS/Askara Helper"];
  CefString(&settings.browser_subprocess_path) = helper.UTF8String;

  g_app = new AskaraCEFApp();
  if (!CefInitialize(args, settings, g_app.get(), nullptr)) {
    g_app = nullptr;
    g_loader.reset();
    SetError(error, @"CefInitialize failed");
    return NO;
  }
  g_initialized = true;
  [[AskaraCEFPump shared] start];
  // Kick the heartbeat so work flows even before CEF asks for it.
  [[AskaraCEFPump shared] scheduleWork:@0];
  return YES;
}

+ (AskaraCEFRequestContext *)createRequestContextAtCachePath:(NSString *)cachePath
                                                        error:(NSError **)error {
  if (!g_initialized) {
    SetError(error, @"CEF is not initialized");
    return nil;
  }
  AskaraCEFRequestContext *wrapper = [[AskaraCEFRequestContext alloc] init];
  wrapper.cachePath = cachePath;
  // Before OnContextInitialized the context is created lazily by the first browser.
  if (g_ready && !wrapper.cefContext) {
    SetError(error, @"CEF request context creation failed");
    return nil;
  }
  return wrapper;
}

+ (void)doMessageLoopWork {
  if (g_initialized) [[AskaraCEFPump shared] scheduleWork:@0];
}

+ (void)shutdown {
  if (!g_initialized) return;
  [[AskaraCEFPump shared] stop];
  // Every browser must be closed before CefShutdown. Close what is still open (tabs in windows
  // that were not closed before quitting) and pump until OnBeforeClose ran for all of them.
  for (AskaraCEFBrowserView *view in g_views.allObjects) [view close];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
  while ((g_open_browsers > 0 || g_pending_browsers > 0) && deadline.timeIntervalSinceNow > 0) {
    CefDoMessageLoopWork();
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
  }
  if (g_open_browsers > 0 || g_pending_browsers > 0) {
    NSLog(@"Askara: %d CEF browsers still open at shutdown", g_open_browsers + g_pending_browsers);
  }
  // Drain pending work like the reference pump does before CefShutdown.
  for (int i = 0; i < 10; ++i) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, 1);
    CefDoMessageLoopWork();
    [NSThread sleepForTimeInterval:0.01];
  }
  CefShutdown();
  g_app = nullptr;
  g_initialized = false;
  g_ready = false;
  [g_ready_blocks removeAllObjects];
  g_loader.reset();
}
@end
