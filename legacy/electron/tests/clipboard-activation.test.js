const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const source = fs.readFileSync(path.join(__dirname, '../main/index.js'), 'utf8')

function setup(status = 'ok') {
  const calls = [], writes = []
  let timer, fallback = 0, own = true
  const context = {
    nativeClient: { request: async (command, payload) => { calls.push({ command, payload }); return { status, changeCount: 123 } } },
    watcher: { sourceMarker: 'marker', recordOwnWrite() {}, isOwnClipboard: () => own },
    clipboard: { write: payload => writes.push(payload), availableFormats: () => [] },
    nativeImage: {}, logger: { log() {} }, settings: { autoPaste: true }, TEST_MODE: false, isMac: true,
    NATIVE_PASTE_RESPONSE_TIMEOUT_MS: 140, AUTO_PASTE_DELAY_MS: 20, pasteGeneration: 0, pendingPasteTimer: null,
    setTimeout(fn) { timer = fn; return 1 }, clearTimeout() {},
    autoPasteWithCompatibilityFallback: () => fallback++,
  }
  vm.createContext(context)
  vm.runInContext(source.slice(source.indexOf('function requestNativePaste'), source.indexOf('winman.setNativeRequester')) +
    source.slice(source.indexOf('async function writeHistoryClipboard'), source.indexOf('function autoPasteWithCompatibilityFallback')) +
    source.slice(source.indexOf('function autoPaste('), source.indexOf('function togglePanel')), context)
  return { context, calls, writes, runTimer: async () => { timer(); await new Promise(resolve => setImmediate(resolve)) },
    setOwn: value => { own = value }, fallback: () => fallback }
}

test('native copy count is carried into paste and rich fallback writes preserve their formats', async () => {
  const { context, calls, runTimer } = setup()
  const copied = await context.writeHistoryClipboard({ type: 'text', text: 'text', html: '<b>text</b>' })
  context.autoPaste(copied); await runTimer()
  assert.equal(calls[0].payload.marker, 'marker')
  assert.equal(calls[1].payload.changeCount, 123)
  const fallback = setup('unavailable')
  await fallback.context.writeHistoryClipboard({ type: 'text', text: 'text', html: '<b>text</b>' })
  assert.equal(fallback.writes[0].html, '<b>text</b>')
})

test('ambiguous paste responses do not start a second compatibility paste', async () => {
  for (const status of ['timeout', 'disconnected', 'stale']) {
    const { context, runTimer, fallback } = setup(status)
    context.autoPaste(); await runTimer()
    assert.equal(fallback(), 0)
  }
})

test('a subsequent external copy cancels pending automatic paste', async () => {
  const { context, calls, runTimer, setOwn } = setup()
  context.autoPaste({ changeCount: 123 }); setOwn(false); await runTimer()
  assert.equal(calls.length, 0)
})
