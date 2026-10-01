#import "CEFBridge.h"

#include <crt_externs.h>
#include <mach-o/dyld.h>
#include <algorithm>
#include <atomic>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
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
std::atomic<uint64_t> g_pump_generation{0};

void SetError(NSError **error, NSString *message) {
  if (!error) return;
  *error = [NSError errorWithDomain:kCEFBridgeErrorDomain
                               code:kCEFBridgeError
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

class AskaraCEFApp final : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  void OnContextInitialized() override {
    CEF_REQUIRE_UI_THREAD();
    dispatch_async(dispatch_get_main_queue(), ^{
      g_ready = true;
      NSArray<dispatch_block_t> *blocks = [g_ready_blocks copy];
      [g_ready_blocks removeAllObjects];
      for (dispatch_block_t block in blocks) block();
    });
  }

  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    const uint64_t generation = ++g_pump_generation;
    const int64_t bounded_delay = std::max<int64_t>(0, delay_ms);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, bounded_delay * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
      if (generation == g_pump_generation.load() && g_initialized) CefDoMessageLoopWork();
    });
  }

  IMPLEMENT_REFCOUNTING(AskaraCEFApp);
};
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

@interface AskaraCEFRequestContext () {
 @package
  CefRefPtr<CefRequestContext> _context;
}
@property(nonatomic, readwrite, copy) NSString *cachePath;
@end

@implementation AskaraCEFRequestContext
- (void)invalidate { _context = nullptr; }
- (void)dealloc { _context = nullptr; }
@end

@implementation AskaraCEFBridge

+ (NSApplication *)application { return [AskaraCEFApplication sharedApplication]; }

+ (BOOL)isInitialized { return g_initialized; }

+ (void)whenReady:(dispatch_block_t)block {
  if (g_ready) {
    dispatch_async(dispatch_get_main_queue(), block);
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

  NSString *helper = [[NSBundle mainBundle].bundlePath
      stringByAppendingPathComponent:@"Contents/Frameworks/Askara Helper.app/Contents/MacOS/Askara Helper"];
  CefString(&settings.browser_subprocess_path) = helper.UTF8String;

  CefRefPtr<AskaraCEFApp> app(new AskaraCEFApp());
  if (!CefInitialize(args, settings, app.get(), nullptr)) {
    g_loader.reset();
    SetError(error, @"CefInitialize failed");
    return NO;
  }
  g_initialized = true;
  return YES;
}

+ (AskaraCEFRequestContext *)createRequestContextAtCachePath:(NSString *)cachePath
                                                        error:(NSError **)error {
  if (!g_initialized) {
    SetError(error, @"CEF is not initialized");
    return nil;
  }
  CefRequestContextSettings settings;
  CefString(&settings.cache_path) = cachePath.UTF8String;
  settings.persist_session_cookies = true;
  CefRefPtr<CefRequestContext> context = CefRequestContext::CreateContext(settings, nullptr);
  if (!context) {
    SetError(error, @"CEF request context creation failed");
    return nil;
  }
  AskaraCEFRequestContext *wrapper = [[AskaraCEFRequestContext alloc] init];
  wrapper->_context = context;
  wrapper.cachePath = cachePath;
  return wrapper;
}

+ (void)doMessageLoopWork {
  if (g_initialized) CefDoMessageLoopWork();
}

+ (void)shutdown {
  if (!g_initialized) return;
  ++g_pump_generation;
  CefShutdown();
  g_initialized = false;
  g_ready = false;
  [g_ready_blocks removeAllObjects];
  g_loader.reset();
}
@end
