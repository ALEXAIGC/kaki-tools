// Kaki Tools native macOS bridge.
//
// It keeps critical system-facing paths outside Electron's event loop:
// - stdin commands post a paste shortcut without launching AppleScript;
// - NSPasteboard.changeCount emits a line only when clipboard ownership changes;
// - JSON requests write marked clipboard content and resize captured AX windows.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdatomic.h>
#include <math.h>
#include <stdlib.h>

static dispatch_source_t clipboard_timer = NULL;
static CGKeyCode cached_paste_key = 9;
static void respond(const char *status, const char *value) {
  flockfile(stdout);
  if (value && value[0]) {
    printf("%s %s\n", status, value);
  } else {
    printf("%s\n", status);
  }
  fflush(stdout);
  funlockfile(stdout);
}

// Resolve the physical key that produces V in the current input source. A few
// layouts switch to QWERTY when Command is held; for those, macOS expects the
// standard physical V key (9) instead.
static CGKeyCode paste_key_code(void) {
  const CGKeyCode qwerty_v = 9;
  TISInputSourceRef input_source = TISCopyCurrentKeyboardInputSource();
  if (!input_source) return qwerty_v;

  CFStringRef source_id = TISGetInputSourceProperty(input_source, kTISPropertyInputSourceID);
  if (source_id && CFStringFind(source_id, CFSTR("Dvorak-QWERTY"), kCFCompareCaseInsensitive).location != kCFNotFound) {
    CFRelease(input_source);
    return qwerty_v;
  }

  CFDataRef layout_data = TISGetInputSourceProperty(input_source, kTISPropertyUnicodeKeyLayoutData);
  if (!layout_data) {
    CFRelease(input_source);
    return qwerty_v;
  }
  const UCKeyboardLayout *layout = (const UCKeyboardLayout *)CFDataGetBytePtr(layout_data);
  CGKeyCode result = qwerty_v;
  for (UInt16 key = 0; key < 128; key++) {
    UInt32 dead_key_state = 0;
    UniChar output[4] = {0};
    UniCharCount output_length = 0;
    OSStatus status = UCKeyTranslate(layout, key, kUCKeyActionDown, 0, LMGetKbdType(),
      kUCKeyTranslateNoDeadKeysBit, &dead_key_state, 4, &output_length, output);
    if (status == noErr && output_length > 0 && (output[0] == 'v' || output[0] == 'V')) {
      result = (CGKeyCode)key;
      break;
    }
  }
  CFRelease(input_source);
  return result;
}

static bool post_command_v(void) {
  CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
  if (!source) return false;

  CGEventRef command_down = CGEventCreateKeyboardEvent(source, (CGKeyCode)55, true);
  CGEventRef v_down = CGEventCreateKeyboardEvent(source, cached_paste_key, true);
  CGEventRef v_up = CGEventCreateKeyboardEvent(source, cached_paste_key, false);
  CGEventRef command_up = CGEventCreateKeyboardEvent(source, (CGKeyCode)55, false);
  if (!command_down || !v_down || !v_up || !command_up) {
    if (command_down) CFRelease(command_down);
    if (v_down) CFRelease(v_down);
    if (v_up) CFRelease(v_up);
    if (command_up) CFRelease(command_up);
    CFRelease(source);
    return false;
  }

  CGEventSetFlags(command_down, kCGEventFlagMaskCommand);
  CGEventSetFlags(v_down, kCGEventFlagMaskCommand);
  CGEventSetFlags(v_up, kCGEventFlagMaskCommand);
  CGEventPost(kCGHIDEventTap, command_down);
  CGEventPost(kCGHIDEventTap, v_down);
  CGEventPost(kCGHIDEventTap, v_up);
  CGEventPost(kCGHIDEventTap, command_up);

  CFRelease(command_down);
  CFRelease(v_down);
  CFRelease(v_up);
  CFRelease(command_up);
  CFRelease(source);
  return true;
}

static void start_clipboard_monitor(void) {
  @autoreleasepool {
    __block NSInteger change_count = [[NSPasteboard generalPasteboard] changeCount];
    clipboard_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
      dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(clipboard_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
      50 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(clipboard_timer, ^{
      @autoreleasepool {
        NSInteger current = [[NSPasteboard generalPasteboard] changeCount];
        if (current == change_count) return;
        change_count = current;
        char count[32];
        snprintf(count, sizeof(count), "%ld", (long)current);
        respond("clipboard", count);
      }
    });
    dispatch_resume(clipboard_timer);
  }
}


// All window AX calls stay on one queue. Clipboard notifications and paste remain
// independent, even when an unresponsive application makes an AX request slow.
static dispatch_queue_t window_queue;
static _Atomic unsigned long long latest_window_generation = 0;
static AXUIElementRef captured_window = NULL;
static pid_t captured_pid = 0;
static unsigned long long captured_generation = 0;
static unsigned long long capture_token = 0;

static void respond_result(NSString *request_id, NSDictionary *result) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
  NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  NSString *value = [NSString stringWithFormat:@"%@ %@", request_id, json ?: @"{\"status\":\"error\"}"];
  respond("result", value.UTF8String);
}

static NSDictionary *failure(NSString *status, NSString *message) {
  return message ? @{ @"status": status, @"message": message } : @{ @"status": status };
}

static bool expired(NSDictionary *request) {
  NSNumber *deadline = request[@"deadline"];
  return ![deadline isKindOfClass:[NSNumber class]] || !isfinite(deadline.doubleValue) ||
    deadline.doubleValue <= [NSDate date].timeIntervalSince1970 * 1000;
}

static AXUIElementRef copy_focused_window(pid_t pid) {
  AXUIElementRef app_element = AXUIElementCreateApplication(pid);
  AXUIElementSetMessagingTimeout(app_element, 0.2);
  CFTypeRef window = NULL;
  AXUIElementCopyAttributeValue(app_element, kAXFocusedWindowAttribute, &window);
  if (!window) {
    CFTypeRef windows = NULL;
    if (AXUIElementCopyAttributeValue(app_element, kAXWindowsAttribute, &windows) == kAXErrorSuccess &&
        windows && CFGetTypeID(windows) == CFArrayGetTypeID() && CFArrayGetCount(windows) > 0) {
      window = CFRetain(CFArrayGetValueAtIndex(windows, 0));
    }
    if (windows) CFRelease(windows);
  }
  CFRelease(app_element);
  if (window && CFGetTypeID(window) != AXUIElementGetTypeID()) {
    CFRelease(window);
    return NULL;
  }
  if (window) AXUIElementSetMessagingTimeout((AXUIElementRef)window, 0.2);
  return (AXUIElementRef)window;
}

static bool read_window_rect(AXUIElementRef window, CGRect *rect) {
  CFTypeRef position = NULL, size = NULL;
  AXUIElementCopyAttributeValue(window, kAXPositionAttribute, &position);
  AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &size);
  CGPoint point = CGPointZero;
  CGSize dimensions = CGSizeZero;
  bool valid = position && size && CFGetTypeID(position) == AXValueGetTypeID() &&
    CFGetTypeID(size) == AXValueGetTypeID() &&
    AXValueGetValue((AXValueRef)position, kAXValueCGPointType, &point) &&
    AXValueGetValue((AXValueRef)size, kAXValueCGSizeType, &dimensions);
  if (position) CFRelease(position);
  if (size) CFRelease(size);
  valid = valid && isfinite(point.x) && isfinite(point.y) && isfinite(dimensions.width) &&
    isfinite(dimensions.height) && dimensions.width > 0 && dimensions.height > 0;
  if (valid) *rect = (CGRect){ point, dimensions };
  return valid;
}

static NSDictionary *rect_dictionary(CGRect rect) {
  return @{ @"x": @(rect.origin.x), @"y": @(rect.origin.y),
    @"width": @(rect.size.width), @"height": @(rect.size.height) };
}

static bool current_window_request(unsigned long long generation, NSDictionary *request) {
  return generation == atomic_load(&latest_window_generation) && !expired(request);
}

static NSDictionary *window_snapshot(NSDictionary *request) {
  NSDictionary *payload = request[@"payload"];
  unsigned long long generation = [payload[@"generation"] unsignedLongLongValue];
  if (!current_window_request(generation, request)) return failure(@"stale", nil);
  if (!AXIsProcessTrusted()) return failure(@"error", @"assistive access not allowed (-25211)");
  NSRunningApplication *application = [NSWorkspace sharedWorkspace].frontmostApplication;
  if (!application) return failure(@"error", @"找不到前台应用");
  pid_t pid = application.processIdentifier;
  if (pid == getppid()) return failure(@"self", nil);
  AXUIElementRef window = copy_focused_window(pid);
  CGRect rect;
  if (!window || !read_window_rect(window, &rect)) {
    if (window) CFRelease(window);
    return failure(@"error", @"无法读取前台窗口");
  }
  if (!current_window_request(generation, request)) {
    CFRelease(window);
    return failure(@"stale", nil);
  }
  if (captured_window) CFRelease(captured_window);
  captured_window = window;
  captured_pid = pid;
  captured_generation = generation;
  capture_token++;
  return @{ @"status": @"ok", @"pid": @(pid), @"token": @(capture_token), @"rect": rect_dictionary(rect) };
}

static bool captured_focus_is_current(unsigned long long generation, NSDictionary *request) {
  if (!current_window_request(generation, request) ||
      [NSWorkspace sharedWorkspace].frontmostApplication.processIdentifier != captured_pid) return false;
  AXUIElementRef focused = copy_focused_window(captured_pid);
  bool same = focused && CFEqual(focused, captured_window);
  if (focused) CFRelease(focused);
  return same && current_window_request(generation, request);
}

static NSDictionary *window_apply(NSDictionary *request) {
  NSDictionary *payload = request[@"payload"];
  unsigned long long generation = [payload[@"generation"] unsignedLongLongValue];
  if (!current_window_request(generation, request) || generation != captured_generation ||
      [payload[@"token"] unsignedLongLongValue] != capture_token ||
      [payload[@"pid"] intValue] != captured_pid || !captured_window) return failure(@"stale", nil);
  if (!AXIsProcessTrusted()) return failure(@"error", @"assistive access not allowed (-25211)");
  NSRunningApplication *application = [NSWorkspace sharedWorkspace].frontmostApplication;
  if (application.processIdentifier != captured_pid) return failure(@"stale", nil);
  AXUIElementRef focused = copy_focused_window(captured_pid);
  bool same_window = focused && CFEqual(focused, captured_window);
  if (focused) CFRelease(focused);
  if (!same_window || !current_window_request(generation, request)) return failure(@"stale", nil);

  NSDictionary *frame = payload[@"rect"];
  if (![frame isKindOfClass:[NSDictionary class]]) return failure(@"error", @"窗口尺寸无效");
  for (NSString *key in @[ @"x", @"y", @"width", @"height" ]) {
    if (![frame[key] isKindOfClass:[NSNumber class]] || !isfinite([frame[key] doubleValue])) {
      return failure(@"error", @"窗口尺寸无效");
    }
  }
  CGSize size = CGSizeMake([frame[@"width"] doubleValue], [frame[@"height"] doubleValue]);
  CGPoint position = CGPointMake([frame[@"x"] doubleValue], [frame[@"y"] doubleValue]);
  if (size.width <= 0 || size.height <= 0) return failure(@"error", @"窗口尺寸无效");
  AXValueRef size_value = AXValueCreate(kAXValueCGSizeType, &size);
  AXValueRef position_value = AXValueCreate(kAXValueCGPointType, &position);
  Boolean size_settable = false;
  AXUIElementIsAttributeSettable(captured_window, kAXSizeAttribute, &size_settable);
  if (!captured_focus_is_current(generation, request)) {
    CFRelease(size_value); CFRelease(position_value);
    return failure(@"stale", nil);
  }
  AXError size_error = size_settable ? AXUIElementSetAttributeValue(captured_window, kAXSizeAttribute, size_value) : kAXErrorSuccess;
  AXError position_error = kAXErrorFailure;
  if (captured_focus_is_current(generation, request)) {
    position_error = AXUIElementSetAttributeValue(captured_window, kAXPositionAttribute, position_value);
    // Some applications enforce a different size while moving between displays.
    if (size_settable && captured_focus_is_current(generation, request)) {
      size_error = AXUIElementSetAttributeValue(captured_window, kAXSizeAttribute, size_value);
    }
  }
  CFRelease(size_value);
  CFRelease(position_value);
  if (!captured_focus_is_current(generation, request)) return failure(@"stale", nil);
  if (position_error != kAXErrorSuccess || size_error != kAXErrorSuccess) {
    return failure(@"error", [NSString stringWithFormat:@"AX 窗口调整失败 (%d/%d)", position_error, size_error]);
  }
  CGRect actual;
  if (read_window_rect(captured_window, &actual)) {
    return @{ @"status": @"ok", @"rect": rect_dictionary(actual),
      @"constrained": @(!CGSizeEqualToSize(actual.size, size)) };
  }
  return failure(@"ok", nil);
}

static NSDictionary *clipboard_write(NSDictionary *request, NSPasteboard *pasteboard) {
  if (expired(request)) return failure(@"stale", nil);
  NSDictionary *payload = request[@"payload"];
  NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
  NSString *file = payload[@"file"];
  if ([file isKindOfClass:[NSString class]]) {
    NSData *png = [NSData dataWithContentsOfFile:file options:NSDataReadingMappedIfSafe error:NULL];
    if (!png.length) return failure(@"error", @"图片文件不可用");
    [item setData:png forType:NSPasteboardTypePNG];
  } else {
    NSString *text = payload[@"text"];
    if (![text isKindOfClass:[NSString class]]) return failure(@"error", @"复制内容无效");
    [item setString:text forType:NSPasteboardTypeString];
    NSString *html = payload[@"html"], *rtf = payload[@"rtf"];
    if ([html isKindOfClass:[NSString class]]) [item setString:html forType:NSPasteboardTypeHTML];
    if ([rtf isKindOfClass:[NSString class]]) [item setData:[rtf dataUsingEncoding:NSUTF8StringEncoding] forType:NSPasteboardTypeRTF];
  }
  NSString *marker = payload[@"marker"];
  if (![marker isKindOfClass:[NSString class]]) return failure(@"error", @"复制来源无效");
  [item setString:marker forType:@"com.kakitools.source"];
  // Content and source travel together; appending a type with a separate Electron
  // writeBuffer call would clear the text/image in this project's Electron version.
  if (expired(request)) return failure(@"stale", nil);
  [pasteboard clearContents];
  if (![pasteboard writeObjects:@[item]]) return failure(@"error", nil);
  return @{ @"status": @"ok", @"changeCount": @(pasteboard.changeCount) };

}

static void handle_request(NSString *request_id, NSDictionary *request) {
  NSString *command = request[@"command"];
  NSDictionary *payload = request[@"payload"];
  if (![command isKindOfClass:[NSString class]] || ![payload isKindOfClass:[NSDictionary class]]) {
    respond_result(request_id, failure(@"error", @"原生请求格式无效"));
    return;
  }
  if ([command hasPrefix:@"window-"]) {
    NSNumber *number = payload[@"generation"];
    if (![number isKindOfClass:[NSNumber class]] || !isfinite(number.doubleValue) || number.doubleValue < 1) {
      respond_result(request_id, failure(@"error", @"窗口请求编号无效"));
      return;
    }
    unsigned long long generation = number.unsignedLongLongValue;
    unsigned long long previous = atomic_load(&latest_window_generation);
    while (generation > previous && !atomic_compare_exchange_weak(&latest_window_generation, &previous, generation)) {}
    dispatch_async(window_queue, ^{
      @autoreleasepool {
        NSDictionary *result = [command isEqualToString:@"window-snapshot"] ? window_snapshot(request) :
          [command isEqualToString:@"window-apply"] ? window_apply(request) : failure(@"unsupported", nil);
        respond_result(request_id, result);
      }
    });
    return;
  }
  if (expired(request)) {
    respond_result(request_id, failure(@"stale", nil));
  } else if ([command isEqualToString:@"clipboard-write"]) {
    respond_result(request_id, clipboard_write(request, [NSPasteboard generalPasteboard]));
  } else if ([command isEqualToString:@"paste"]) {
    NSNumber *expected_count = payload[@"changeCount"];
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    if (expected_count && (![expected_count isKindOfClass:[NSNumber class]] ||
        pasteboard.changeCount != expected_count.integerValue ||
        ![[pasteboard stringForType:@"com.kakitools.source"] isEqualToString:payload[@"marker"]])) {
      respond_result(request_id, failure(@"stale", nil));
    } else respond_result(request_id, failure(!AXIsProcessTrusted() ? @"not-trusted" : post_command_v() ? @"ok" : @"error", nil));
  } else respond_result(request_id, failure(@"unsupported", nil));
}

int main(void) {
  @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    cached_paste_key = paste_key_code();
    window_queue = dispatch_queue_create("com.kakitools.windows", DISPATCH_QUEUE_SERIAL);
    start_clipboard_monitor();
    respond("ready", AXIsProcessTrusted() ? "1 requests windows clipboard-write" : "0 requests windows clipboard-write");

    char *input = NULL;
    size_t capacity = 0;
    while (getline(&input, &capacity, stdin) >= 0) {
      @autoreleasepool {
        if (strncmp(input, "request ", 8) == 0) {
          char *request_id = input + 8;
          char *json = strchr(request_id, ' ');
          if (!json) continue;
          *json++ = '\0';
          NSString *identifier = [NSString stringWithUTF8String:request_id];
          NSData *data = [[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding];
          id request = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
          if ([request isKindOfClass:[NSDictionary class]]) handle_request(identifier, request);
          else respond_result(identifier, failure(@"error", @"原生请求 JSON 无效"));
        } else if (strncmp(input, "paste ", 6) == 0) {
          char *request_id = input + 6;
          request_id[strcspn(request_id, "\r\n")] = '\0';
          respond(!AXIsProcessTrusted() ? "not-trusted" : post_command_v() ? "ok" : "error", request_id);
        } else if (strncmp(input, "status", 6) == 0) {
          respond("status", AXIsProcessTrusted() ? "1" : "0");
        } else if (strncmp(input, "quit", 4) == 0) break;
      }
    }
    free(input);
    if (clipboard_timer) dispatch_source_cancel(clipboard_timer);
    dispatch_sync(window_queue, ^{});
    if (captured_window) CFRelease(captured_window);
    return 0;
  }
}
