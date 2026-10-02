const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const { EventEmitter } = require('node:events')

function setup() {
  const children = []
  class Child extends EventEmitter {
    constructor() {
      super(); this.exitCode = this.signalCode = null
      this.stdout = new EventEmitter(); this.stderr = new EventEmitter()
      this.stdout.setEncoding = this.stderr.setEncoding = () => {}
    }
    kill() { this.killed = true }
  }
  const context = { module: { exports: {} }, process, console, Date,
    setTimeout: () => ({ unref() {} }), clearTimeout() {},
    require: name => name === 'fs' ? { existsSync: () => true } : name === 'child_process' ? {
      spawn() { const child = new Child(); children.push(child); return child }, execFileSync() {},
    } : require(name) }
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../main/deskflow.js'), 'utf8'), context)
  const core = new context.module.exports.DeskflowCore({ userData: '/isolated', deviceName: 'test', binaryPath: '/fake' })
  core.identity = () => ({ display: 'fake' })
  return { core, children }
}

test('output from stopped or replaced Deskflow children cannot resurrect an old peer', () => {
  const { core, children } = setup()
  let updates = 0
  core.on('status', () => updates++)
  core._spawn('server'); core.role = 'host'; core.stop()
  const stoppedUpdates = updates
  children[0].stdout.emit('data', '"previous-peer" has connected\n')
  assert.equal(core.peer, null)
  assert.equal(core.role, 'idle')
  assert.equal(updates, stoppedUpdates)
  core._spawn('server')
  children[0].stderr.emit('data', '"previous-peer" has connected\n')
  assert.equal(core.peer, null)
  assert.equal(updates, stoppedUpdates)
})

test('invalid layout numbers produce no persistent changes or restart', () => {
  const { core } = setup()
  core._layout = new Map([['test', { col: 2, row: 1 }]])
  let writes = 0
  core._saveLayout = core._writeServerConfig = core._spawn = () => writes++
  for (const value of [undefined, NaN, Infinity, -1, 100]) {
    assert.equal(core.setLayout('test', value, 1), false)
    assert.equal(core.setLayout('test', 2, value), false)
  }
  assert.equal(writes, 0)
  assert.deepEqual(core._layout.get('test'), { col: 2, row: 1 })
  assert.equal(core.setLayout('test', 1, 1), true)
  assert.equal(writes > 0, true)
})
