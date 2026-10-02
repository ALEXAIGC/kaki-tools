const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const { execFileSync } = require('node:child_process')

// Use a private NSPasteboard for writes; never overwrite or read the user's clipboard.
test('native clipboard preserves text, formatting and source together on a private pasteboard', { skip: process.platform !== 'darwin' }, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaki-native-protocol-'))
  try {
    const source = path.join(dir, 'test.m'), binary = path.join(dir, 'test')
    const native = path.resolve(__dirname, '../native/kaki-fast-paste.m')
    fs.writeFileSync(source, `#define main kaki_helper_main
#include ${JSON.stringify(native)}
#undef main
#include <assert.h>
int main(void) {
  @autoreleasepool {
    NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
    NSDictionary *payload = @{ @"text": @"中文\\nsecond line", @"html": @"<b>中文</b>",
      @"rtf": @"{\\\\rtf1 text}", @"marker": @"test-owner" };
    NSDictionary *request = @{ @"deadline": @([NSDate date].timeIntervalSince1970 * 1000 + 5000), @"payload": payload };
    NSDictionary *result = clipboard_write(request, board);
    assert([result[@"status"] isEqualToString:@"ok"]);
    assert([result[@"changeCount"] integerValue] == board.changeCount);
    assert([[board stringForType:NSPasteboardTypeString] isEqualToString:payload[@"text"]]);
    assert([[board stringForType:NSPasteboardTypeHTML] isEqualToString:payload[@"html"]]);
    assert([[board stringForType:NSPasteboardTypeRTF] isEqualToString:payload[@"rtf"]]);
    assert([[board stringForType:@"com.kakitools.source"] isEqualToString:@"test-owner"]);
    NSDictionary *expired_request = @{ @"deadline": @0, @"payload": @{ @"text": @"must not replace", @"marker": @"different" } };
    assert([clipboard_write(expired_request, board)[@"status"] isEqualToString:@"stale"]);
    assert([[board stringForType:NSPasteboardTypeString] isEqualToString:payload[@"text"]]);
    [board clearContents];
    puts("private clipboard protocol passed");
  }
  return 0;
}`)
    execFileSync('/usr/bin/clang', ['-O2', '-Wall', '-Wextra', '-Werror', '-fobjc-arc', '-framework', 'AppKit', '-framework', 'ApplicationServices', '-framework', 'Carbon', source, '-o', binary], { timeout: 20000 })
    assert.match(execFileSync(binary, [], { encoding: 'utf8', timeout: 10000 }), /private clipboard protocol passed/)
    const expired = ['paste', 'clipboard-write', 'window-snapshot', 'window-apply'].map((command, n) =>
      `request ${n + 1} ${JSON.stringify({ command, payload: { generation: 1 }, deadline: 0 })}`).join('\n')
    // Compile the production entry point separately so expired commands exercise
    // the actual stdin parser and action dispatch, without posting any OS events.
    execFileSync('/usr/bin/clang', ['-O2', '-Wall', '-Wextra', '-Werror', '-fobjc-arc', '-framework', 'AppKit', '-framework', 'ApplicationServices', '-framework', 'Carbon', native, '-o', binary], { timeout: 20000 })
    const replies = execFileSync(binary, [], { input: expired + '\nquit\n', encoding: 'utf8', timeout: 10000 })
    for (let id = 1; id <= 4; id++) assert.match(replies, new RegExp(`result ${id} .*"status":"stale"`))
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})
