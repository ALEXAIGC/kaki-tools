// Kaki Tools native macOS bridge.
//
// It keeps both critical system-facing paths outside Electron's event loop:
// - stdin commands post a paste shortcut without launching AppleScript;
// - NSPasteboard.changeCount emits a line only when clipboard ownership changes.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>

static dispatch_source_t clipboard_timer = NULL;
static CGKeyCode cached_paste_key = 9;
static CFMachPortRef control_tap = NULL;
static CFRunLoopSourceRef control_source = NULL;
static CFRunLoopRef control_run_loop = NULL;
static bool control_enabled = false;
static bool control_remote = false;

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

static void emit_input(const char *kind, const char *action, long a, long b) {
  char line[96];
  snprintf(line, sizeof(line), "%s %s %ld %ld", kind, action, a, b);
  respond("input", line);
}

static CGEventRef control_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
  (void)proxy; (void)refcon;
  if (!control_enabled) return event;
  if (!control_remote && type == kCGEventMouseMoved) {
    CGPoint point = CGEventGetLocation(event);
    CGRect frame = CGDisplayBounds(CGMainDisplayID());
    if (point.x >= CGRectGetMaxX(frame) - 1) {
      control_remote = true;
      respond("control", "entered");
      return NULL;
    }
  }
  if (!control_remote) return event;
  if (type == kCGEventKeyDown && CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) == 53) {
    control_remote = false;
    respond("control", "exited");
    return NULL;
  }
  if (type == kCGEventMouseMoved) {
    emit_input("mouse", "move", CGEventGetIntegerValueField(event, kCGMouseEventDeltaX), CGEventGetIntegerValueField(event, kCGMouseEventDeltaY));
  } else if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
    emit_input("key", type == kCGEventKeyDown ? "down" : "up", CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode), CGEventGetFlags(event));
  } else if (type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp || type == kCGEventRightMouseDown || type == kCGEventRightMouseUp) {
    const bool right = type == kCGEventRightMouseDown || type == kCGEventRightMouseUp;
    emit_input("button", (type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown) ? "down" : "up", right ? 1 : 0, 0);
  } else if (type == kCGEventScrollWheel) {
    emit_input("scroll", "wheel", CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1), CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2));
  } else {
    return event;
  }
  return NULL;
}

static void *control_thread(void *unused) {
  (void)unused;
  @autoreleasepool {
    CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved) | CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) |
      CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) | CGEventMaskBit(kCGEventRightMouseDown) |
      CGEventMaskBit(kCGEventRightMouseUp) | CGEventMaskBit(kCGEventScrollWheel);
    control_tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, 0, mask, control_callback, NULL);
    if (!control_tap) { respond("control", "error"); return NULL; }
    control_source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, control_tap, 0);
    control_run_loop = CFRunLoopGetCurrent();
    CFRunLoopAddSource(control_run_loop, control_source, kCFRunLoopCommonModes);
    CGEventTapEnable(control_tap, true);
    respond("control", "ready");
    CFRunLoopRun();
  }
  return NULL;
}

static void start_control(void) {
  if (control_enabled) return;
  control_enabled = true; control_remote = false;
  pthread_t thread;
  pthread_create(&thread, NULL, control_thread, NULL);
  pthread_detach(thread);
}

static void stop_control(void) {
  control_enabled = false; control_remote = false;
  if (control_tap) CGEventTapEnable(control_tap, false);
  if (control_run_loop) CFRunLoopStop(control_run_loop);
  control_tap = NULL; control_source = NULL; control_run_loop = NULL;
  respond("control", "stopped");
}

static void inject_event(const char *kind, const char *action, long a, long b) {
  CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
  if (!source) return;
  CGEventRef snapshot = CGEventCreate(NULL);
  CGPoint current = snapshot ? CGEventGetLocation(snapshot) : CGPointZero;
  if (snapshot) CFRelease(snapshot);
  if (strcmp(kind, "key") == 0) {
    CGEventRef event = CGEventCreateKeyboardEvent(source, (CGKeyCode)a, strcmp(action, "down") == 0);
    if (event) { CGEventSetFlags(event, (CGEventFlags)b); CGEventPost(kCGHIDEventTap, event); CFRelease(event); }
  } else if (strcmp(kind, "mouse") == 0) {
    CGPoint next = CGPointMake(current.x + a, current.y + b);
    CGEventRef event = CGEventCreateMouseEvent(source, kCGEventMouseMoved, next, kCGMouseButtonLeft);
    if (event) { CGEventPost(kCGHIDEventTap, event); CFRelease(event); }
  } else if (strcmp(kind, "button") == 0) {
    const CGMouseButton button = a == 1 ? kCGMouseButtonRight : kCGMouseButtonLeft;
    const CGEventType type = button == kCGMouseButtonRight ? (strcmp(action, "down") == 0 ? kCGEventRightMouseDown : kCGEventRightMouseUp) : (strcmp(action, "down") == 0 ? kCGEventLeftMouseDown : kCGEventLeftMouseUp);
    CGEventRef event = CGEventCreateMouseEvent(source, type, current, button);
    if (event) { CGEventPost(kCGHIDEventTap, event); CFRelease(event); }
  } else if (strcmp(kind, "scroll") == 0) {
    CGEventRef event = CGEventCreateScrollWheelEvent(source, kCGScrollEventUnitLine, 2, (int32_t)a, (int32_t)b);
    if (event) { CGEventPost(kCGHIDEventTap, event); CFRelease(event); }
  }
  CFRelease(source);
}

int main(void) {
  setvbuf(stdout, NULL, _IONBF, 0);
  // 键盘布局查询首次调用可能触发系统服务初始化。启动时预热并缓存，避免
  // 用户第一次点击时超过主进程的兼容后备时间而导致双重粘贴。
  cached_paste_key = paste_key_code();
  start_clipboard_monitor();
  respond("ready", AXIsProcessTrusted() ? "1" : "0");

  char input[128];
  while (fgets(input, sizeof(input), stdin)) {
    if (strncmp(input, "paste ", 6) == 0) {
      char *request_id = input + 6;
      request_id[strcspn(request_id, "\r\n")] = '\0';
      if (!AXIsProcessTrusted()) {
        respond("not-trusted", request_id);
      } else if (post_command_v()) {
        respond("ok", request_id);
      } else {
        respond("error", request_id);
      }
    } else if (strncmp(input, "status", 6) == 0) {
      respond("status", AXIsProcessTrusted() ? "1" : "0");
    } else if (strncmp(input, "quit", 4) == 0) {
      break;
    } else if (strncmp(input, "control start", 13) == 0) {
      start_control();
    } else if (strncmp(input, "control stop", 12) == 0) {
      stop_control();
    } else if (strncmp(input, "inject ", 7) == 0) {
      char kind[16] = {0}, action[16] = {0}; long a = 0, b = 0;
      if (sscanf(input + 7, "%15s %15s %ld %ld", kind, action, &a, &b) == 4) inject_event(kind, action, a, b);
    }
  }
  if (clipboard_timer) dispatch_source_cancel(clipboard_timer);
  return 0;
}
