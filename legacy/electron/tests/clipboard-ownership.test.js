const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')

function setup() {
  const state = { text: '', html: '', marker: '', image: null }
  const received = []
  const clipboard = {
    availableFormats: () => [state.html && 'text/html', state.image && 'image/png', state.marker && 'com.kakitools.source'].filter(Boolean),
    readText: () => state.text, readHTML: () => state.html, readRTF: () => '',
    readBuffer: () => Buffer.from(state.marker), readImage: () => state.image,
  }
  const context = { module: { exports: {} }, Buffer, Date, setTimeout, clearTimeout, setInterval, clearInterval,
    require: name => name === 'electron' ? { clipboard } : name.startsWith('./') ? require('../main/' + name.slice(2)) : require(name) }
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../main/watcher.js'), 'utf8'), context)
  const watcher = new context.module.exports({ onText: (text, rich) => received.push({ text, ...rich }), onImage: () => received.push({ image: true }) })
  return { state, received, watcher }
}

test('own source marker skips history playback but captures the immediately following external copy', () => {
  const { state, received, watcher } = setup()
  state.text = 'from history'; state.marker = watcher.sourceMarker
  watcher.tickFromNativeChange()
  assert.equal(received.length, 0)
  state.marker = ''; state.text = 'new external copy'
  watcher.tickFromNativeChange()
  assert.equal(received[0].text, 'new external copy')
})

test('fallback dedup compares content instead of suppressing a time interval', () => {
  const { state, received, watcher } = setup()
  state.text = 'from history'; state.html = '<b>from history</b>'
  watcher.recordOwnWrite()
  watcher.tickFromNativeChange()
  assert.equal(received.length, 0)
  state.html = '<i>from history</i>'
  watcher.tickFromNativeChange()
  assert.equal(received[0].html, '<i>from history</i>')
  state.text = 'next'; watcher.tickFromNativeChange()
  assert.equal(received[1].text, 'next')
})

test('an external copy of the same image after a marked playback is captured again', () => {
  const { state, received, watcher } = setup()
  state.image = { isEmpty: () => false, getSize: () => ({ width: 5, height: 5 }), resize() { return this }, toBitmap: () => Buffer.alloc(100) }
  watcher.tickFromNativeChange()
  state.marker = watcher.sourceMarker; watcher.tickFromNativeChange()
  state.marker = ''; watcher.tickFromNativeChange()
  assert.equal(received.length, 2)
})

test('authoritative recopy retries the same image while polling still skips unchanged contents', () => {
  const { state, received, watcher } = setup()
  state.image = { isEmpty: () => false, getSize: () => ({ width: 5, height: 5 }), resize() { return this }, toBitmap: () => Buffer.alloc(100) }
  watcher.tickFromNativeChange()
  watcher.tickImage()
  assert.equal(received.length, 1)
  // The first save may have been rejected by a temporarily full queue.
  watcher.tickFromNativeChange()
  assert.equal(received.length, 2)
})
