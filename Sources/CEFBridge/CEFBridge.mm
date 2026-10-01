#import "CEFBridge.h"

#include <crt_externs.h>
#include <mach-o/dyld.h>
#include <algorithm>
#include <atomic>
#include <climits>
#include <cmath>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_callback.h"
#include "include/cef_command_line.h"
#include "include/cef_cookie.h"
#include "include/cef_display_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
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
                              public CefLifeSpanHandler,
                              public CefLoadHandler {
 public:
  explicit AskaraCEFClient(AskaraCEFBrowserView *view) : view_(view) {}

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                     const CefString& target_url, const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition, bool user_gesture,
                     const CefPopupFeatures& popupFeatures, CefWindowInfo& windowInfo,
                     CefRefPtr<CefClient>& client, CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       const CefString& url) override;
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override;
  void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) override;
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool is_loading,
                            bool can_go_back, bool can_go_forward) override;
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                 int http_status_code) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                   ErrorCode error_code, const CefString& error_text,
                   const CefString& failed_url) override;

  CefRefPtr<CefBrowser> browser() const { return browser_; }
  void SetInitialURL(const CefString& url) { initial_url_ = url; }

 private:
  __weak AskaraCEFBrowserView *view_;
  CefRefPtr<CefBrowser> browser_;
  CefString initial_url_;
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
@end

@implementation AskaraCEFBrowserView

- (instancetype)initWithFrame:(NSRect)frame requestContext:(AskaraCEFRequestContext *)requestContext {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.wantsLayer = YES;
  self.pageTitle = @"";
  _estimatedProgress = 0;
  _zoomFactor = 1;
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
    if (self.onLoadFailed) self.onLoadFailed(@"CEF browser prerequisites are missing");
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
    if (self.onLoadFailed) self.onLoadFailed(message);
  }
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

- (void)close {
  if (_closeRequested) return;
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
  _client = nullptr;
  _requestContext = nullptr;
  // Hold the block locally: the handler may release this view (and its blocks) while running.
  dispatch_block_t onClosed = self.onClosed;
  self.onClosed = nil;
  if (onClosed) onClosed();
}
- (void)dealloc {
  if (_client && _client->browser()) _client->browser()->GetHost()->CloseBrowser(true);
}
@end

namespace {
NSString *NSStringFromCEF(const CefString& value) {
  const std::string utf8 = value.ToString();
  return [[NSString alloc] initWithBytes:utf8.data() length:utf8.size() encoding:NSUTF8StringEncoding] ?: @"";
}

void AskaraCEFClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  --g_pending_browsers;
  ++g_open_browsers;
  browser_ = browser;
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
  // Default Alloy popups are bare native windows outside Askara's tab model. Open them as tabs
  // instead. Like WebKit tabs with javaScriptCanOpenWindowsAutomatically = false, only popups
  // from a user gesture are honoured. window.opener is not preserved for Blink tabs yet.
  NSURL *url = [NSURL URLWithString:NSStringFromCEF(target_url)];
  AskaraCEFBrowserView *view = view_;
  if (user_gesture && url && view) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (view.onOpenURLInNewTab) view.onOpenURLInNewTab(url);
    });
  }
  return true;
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

void AskaraCEFClient::OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                int http_status_code) {
  if (frame->IsMain() && view_ && view_.onLoadCompleted) view_.onLoadCompleted();
}

void AskaraCEFClient::OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                  ErrorCode error_code, const CefString& error_text,
                                  const CefString& failed_url) {
  if (frame->IsMain() && view_ && error_code != ERR_ABORTED && view_.onLoadFailed) {
    view_.onLoadFailed(NSStringFromCEF(error_text));
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
  CefString(&settings.root_cache_path) = rootCachePath.UTF8String;
  // Diagnostics only: ASKARA_CEF_VERBOSE=1 writes Chromium's verbose log to chrome_debug.log.
  if (getenv("ASKARA_CEF_VERBOSE")) settings.log_severity = LOGSEVERITY_VERBOSE;

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
