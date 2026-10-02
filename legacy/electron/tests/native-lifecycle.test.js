const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const { EventEmitter } = require('node:events')
const source = fs.readFileSync(path.join(__dirname, '../main/index.js'), 'utf8')

test('native pipe failure disconnects once and old output cannot mutate a replacement bridge', () => {
  const child = new EventEmitter()
  child.stdin = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter()
  child.stdout.setEncoding = () => {}
  child.exitCode = child.signalCode = null
  let kills = 0, disconnects = 0, restarts = 0, lines = 0
  child.kill = () => kills++
  const context = { isMac: true, TEST_MODE: false, nativePasteBridge: null, nativePasteBuffer: '',
    nativePasteRestartAttempts: 0,
    nativeClient: { disconnect: () => disconnects++ },
    nativePasteExecutable: () => '/fake', fs: { existsSync: () => true }, spawn: () => child,
    logger: { log() {} }, setNativeClipboardMonitor() {}, scheduleNativePasteRestart: () => restarts++,
    handleNativePasteLine: () => lines++,
  }
  vm.createContext(context)
  vm.runInContext(source.slice(source.indexOf('function handleNativePasteBridgeStopped'), source.indexOf('function handleNativePasteLine')) +
    source.slice(source.indexOf('function startNativePasteBridge'), source.indexOf('function stopNativePasteBridge')), context)
  context.startNativePasteBridge()
  child.stdout.emit('data', 'ready 1\n')
  assert.equal(lines, 1)
  assert.doesNotThrow(() => child.stdin.emit('error', Object.assign(Error('broken pipe'), { code: 'EPIPE' })))
  assert.equal(disconnects, 1)
  assert.equal(restarts, 1)
  assert.equal(kills, 1)
  context.nativePasteBridge = new EventEmitter()
  child.stdout.emit('data', 'result 1 {"status":"ok"}\n')
  child.emit('exit', 1)
  assert.equal(lines, 1)
  assert.equal(disconnects, 1)
})
