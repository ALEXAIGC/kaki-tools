const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')

const source = fs.readFileSync(path.join(__dirname, '../main/winman.js'), 'utf8')

function fixture({ trusted = true } = {}) {
  const calls = [], logs = [], timers = new Map(), cancelledTimers = []
  let nextTimer = 0
  const context = {
    module: { exports: {} }, process: { platform: 'darwin' },
    setTimeout: fn => { const id = ++nextTimer; timers.set(id, fn); return id },
    clearTimeout: id => { cancelledTimers.push(timers.get(id)); timers.delete(id) },
    require: name => {
      if (name === 'electron') return {
        app: {}, Notification: class { show() {} },
        systemPreferences: { isTrustedAccessibilityClient: () => trusted },
        screen: { getDisplayMatching: () => ({ workArea: { x: 0, y: 25, width: 1200, height: 800 } }) },
      }
      if (name === './log') return { log: (...args) => logs.push(args) }
      if (name === 'child_process') return {
        execFile: (file, args, options, callback) => {
          const call = { file, script: args[1], options, callback, kills: 0 }
          calls.push(call)
          return { kill: () => { call.kills++ } }
        },
      }
      return require(name)
    },
  }
  vm.runInNewContext(source, context)
  return { winman: context.module.exports, calls, logs, timers, cancelledTimers }
}

function deferred() {
  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}
const settle = () => new Promise(resolve => setImmediate(resolve))
const snapshot = { status: 'ok', token: 'focused-1', pid: 123, rect: { x: 10, y: 25, width: 700, height: 600 } }
const readResult = '123|10|25|700|600'

// This ordering reproduced an old left-half read arriving after a new right-half
// read, which previously caused the older command to win.
test('only the latest AppleScript read can move the window', () => {
  const { winman, calls } = fixture()
  winman.arrange('left-half')
  winman.arrange('right-half')
  assert.equal(calls[0].kills, 1)
  calls[1].callback(null, readResult)
  calls[0].callback(null, readResult)
  assert.equal(calls.length, 3)
  assert.match(calls[2].script, /set position of win to \{600, 25\}/)
  assert.match(calls[2].script, /unix id is 123/)
})

test('a newer command cancels an old setting process and ignores its late error', () => {
  const { winman, calls, logs } = fixture()
  winman.arrange('left-half')
  calls[0].callback(null, readResult)
  winman.arrange('right-half')
  assert.equal(calls[1].kills, 1)
  calls[1].callback(new Error('not allowed'))
  calls[2].callback(null, readResult)
  assert.equal(calls.length, 4)
  assert.match(calls[3].script, /set position of win to \{600, 25\}/)
  assert.equal(logs.some(args => String(args[0]).includes('失败')), false)
})

test('a cancelled delay cannot revive its old layout', () => {
  const { winman, calls, timers, cancelledTimers } = fixture()
  winman.arrange('left-half', { delay: 300 })
  assert.equal(calls.length, 0)
  winman.arrange('right-half')
  assert.equal(timers.size, 0)
  cancelledTimers[0]()
  assert.equal(calls.length, 1)
  calls[0].callback(null, readResult)
  assert.match(calls[1].script, /set position of win to \{600, 25\}/)
})

test('SELF focus retries stay in their original generation and run at most once', () => {
  const { winman, calls } = fixture()
  let oldRetry, currentRetry
  winman.arrange('left-half', { onSelf: retry => { oldRetry = retry } })
  calls[0].callback(null, 'SELF')
  winman.arrange('right-half', { onSelf: retry => { currentRetry = retry } })
  calls[1].callback(null, 'SELF')
  oldRetry()
  assert.equal(calls.length, 2)
  currentRetry()
  currentRetry()
  assert.equal(calls.length, 3)
  calls[2].callback(null, readResult)
  assert.match(calls[3].script, /set position of win to \{600, 25\}/)
})

test('a first-run permission prompt survives while only the latest request resumes', () => {
  const { winman, calls } = fixture({ trusted: false })
  winman.arrange('left-half')
  winman.arrange('right-half')
  winman.arrange('maximize')
  assert.equal(calls.length, 1)
  assert.equal(calls[0].kills, 0)
  assert.equal(calls[0].options.timeout, 60000)
  calls[0].callback(null, readResult)
  assert.equal(calls.length, 2)
  calls[1].callback(null, readResult)
  assert.equal(calls.length, 3)
  assert.match(calls[2].script, /set size of win to \{1200, 800\}/)
})

test('native snapshots use the latest generation and preserve the window token', async () => {
  const { winman, calls } = fixture()
  const reads = [], applied = []
  winman.setNativeRequester((command, payload) => {
    if (command === 'window-snapshot') {
      const read = deferred(); reads.push({ ...read, payload }); return read.promise
    }
    applied.push(payload)
    return Promise.resolve({ status: 'ok' })
  })
  winman.arrange('left-half')
  await settle()
  winman.arrange('right-half')
  await settle()
  reads[1].resolve(snapshot)
  await settle()
  reads[0].resolve(snapshot)
  await settle()
  assert.equal(applied.length, 1)
  assert.equal(applied[0].generation, reads[1].payload.generation)
  assert.equal(applied[0].token, snapshot.token)
  assert.equal(applied[0].pid, 123)
  assert.equal(JSON.stringify(applied[0].rect), JSON.stringify({ x: 600, y: 25, width: 600, height: 800 }))
  assert.equal(calls.length, 0)
})

test('unsupported native snapshots fall back to the existing AppleScript path', async () => {
  const { winman, calls } = fixture()
  winman.setNativeRequester(() => Promise.resolve({ status: 'unsupported' }))
  winman.arrange('left-half')
  await settle()
  calls[0].callback(null, readResult)
  assert.equal(calls.length, 2)
  assert.match(calls[1].script, /set position of win to \{0, 25\}/)
})

test('native errors never repeat a window movement through AppleScript', async t => {
  for (const response of [{ status: 'error', message: 'AX denied' }, { status: 'unavailable' }, { status: 'stale' }]) {
    await t.test(response.status, async () => {
      const { winman, calls } = fixture()
      const commands = []
      winman.setNativeRequester(command => {
        commands.push(command)
        return Promise.resolve(command === 'window-snapshot' ? snapshot : response)
      })
      winman.arrange('left-half')
      await settle()
      assert.deepEqual(commands, ['window-snapshot', 'window-apply'])
      assert.equal(calls.length, 0)
    })
  }
})

test('native snapshot failures report the error without starting a second backend', async () => {
  const { winman, calls, logs } = fixture()
  winman.setNativeRequester(() => Promise.reject(new Error('not allowed AX')))
  winman.arrange('left-half')
  await settle()
  assert.equal(calls.length, 0)
  assert.equal(logs.some(args => String(args[0]).includes('失败')), true)
})

test('native SELF retries are invalidated when a newer layout is requested', async () => {
  const { winman, calls } = fixture()
  let retry
  const commands = []
  winman.setNativeRequester((command, payload) => {
    commands.push({ command, payload })
    return Promise.resolve({ status: 'self' })
  })
  winman.arrange('left-half', { onSelf: fn => { retry = fn } })
  await settle()
  winman.arrange('right-half')
  await settle()
  retry()
  await settle()
  assert.equal(commands.length, 2)
  assert.equal(calls.length, 0)
})
