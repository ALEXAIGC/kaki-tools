const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { setTimeout: delay } = require('node:timers/promises')
const Store = require('../main/store')
const { fitImage } = require('../main/image-size')
const img = { getSize: () => ({ width: 4000, height: 100 }), resize: size => {
  assert.ok(size.width <= 280 && size.height <= 140)
  return { toDataURL: () => 'thumbnail' }
} }
function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaki-image-test-'))
  const store = new Store(dir)
  t.after(async () => { await delay(30); store.flushSync(); await delay(30); fs.rmSync(dir, { recursive: true, force: true }) })
  return { dir, store }
}
async function settled(store) {
  for (let i = 0; i < 100 && (store._pendingImages.size || store.list().some(i => i.thumb)); i++) await delay(10)
  assert.equal(store._pendingImages.size, 0)
}
test('extreme image aspect ratios stay inside both bounds without upscaling', () => {
  for (const [width, height] of [[1, 100000], [100000, 1], [4000, 3000], [1, 1]]) {
    for (const [maxWidth, maxHeight] of [[64, 64], [280, 140]]) {
      const size = fitImage(width, height, maxWidth, maxHeight)
      assert.ok(size.width >= 1 && size.width <= Math.min(width, maxWidth))
      assert.ok(size.height >= 1 && size.height <= Math.min(height, maxHeight))
    }
  }
})
test('async image writes preserve capture order, previews and reload', async t => {
  const { store, dir } = fixture(t)
  store.addImage(img, Buffer.from('first'), 'first')
  const first = store.list()[0]
  assert.equal(await store.getThumbnail(first.id), 'thumbnail')
  store.addText('between')
  store.addImage(img, Buffer.from('last'), 'last')
  await settled(store)
  assert.deepEqual(store.list().map(i => i.hash || i.text), ['last', 'between', 'first'])
  store.flushSync()
  const loaded = new Store(dir)
  assert.equal(fs.readFileSync(loaded.list()[0].file, 'utf8'), 'last')
  assert.equal(await loaded.getThumbnail(first.id), 'thumbnail')
})
test('deleting a pending image does not resurrect files or history', async t => {
  const { store, dir } = fixture(t)
  store.addImage(img, Buffer.alloc(1024 * 1024), 'deleted')
  const item = store.list()[0]
  store.remove(item.id)
  await delay(80)
  store.flushSync()
  assert.equal(fs.existsSync(item.file), false)
  assert.equal(fs.existsSync(item.file + '.pending'), false)
  assert.equal(new Store(dir).list().length, 0)
})
test('immediate exit saves pending images and embedded preview', async t => {
  const { store, dir } = fixture(t)
  store.addImage(img, Buffer.from('exit-image'), 'exit')
  store.flushSync()
  const loaded = new Store(dir)
  assert.equal(fs.readFileSync(loaded.list()[0].file, 'utf8'), 'exit-image')
  assert.equal(await loaded.getThumbnail(loaded.list()[0].id), 'thumbnail')
  await delay(30)
  assert.equal(fs.readFileSync(loaded.list()[0].file, 'utf8'), 'exit-image')
})
test('immediate board copy remains independent when the original is deleted', async t => {
  const { store } = fixture(t)
  store.createBoard('saved')
  store.addImage(img, Buffer.from('board-image'), 'board')
  const original = store.list()[0]
  store.addToBoard(original.id, 'saved')
  const clone = store.list()[0]
  store.remove(original.id)
  await delay(50)
  assert.equal(fs.readFileSync(clone.file, 'utf8'), 'board-image')
  assert.equal(await store.getThumbnail(clone.id), 'thumbnail')
})

test('background encoder preserves BGRA colors and unpremultiplies alpha', async () => {
  const { PNG } = require('pngjs')
  const { encodeImage } = require('../main/image-encoder')
  const native = { getSize: () => ({ width: 3, height: 1 }),
    toBitmap: () => Buffer.from([25,50,100,128, 200,100,50,255, 0,0,0,0]) }
  const encoded = await encodeImage(native)
  assert.deepEqual([...PNG.sync.read(encoded).data], [199,100,50,128, 50,100,200,255, 0,0,0,0])
})
test('background image encoding and async saving survive reload', async t => {
  const { store, dir } = fixture(t)
  const native = { getSize: () => ({ width: 1, height: 1 }), toBitmap: () => Buffer.from([30,20,10,255]),
    resize: () => ({ toDataURL: () => 'thumbnail' }), toPNG: () => { throw Error('must use worker') } }
  store.addImage(native, null, 'worker')
  await settled(store)
  store.flushSync()
  const { PNG } = require('pngjs')
  assert.deepEqual([...PNG.sync.read(fs.readFileSync(new Store(dir).list()[0].file)).data], [10,20,30,255])
})
test('exit during encoding saves the native PNG before the worker finishes', async t => {
  const { store, dir } = fixture(t)
  const native = { ...img, toBitmap: () => Buffer.alloc(4000*100*4), toPNG: () => Buffer.from('exit-before-encode') }
  store.addImage(native, null, 'encoding')
  store.flushSync()
  const item = new Store(dir).list()[0]
  assert.equal(fs.readFileSync(item.file, 'utf8'), 'exit-before-encode')
  await delay(60)
  assert.equal(fs.readFileSync(item.file, 'utf8'), 'exit-before-encode')
})
test('failed async image write removes the unsaved record', async t => {
  const { store } = fixture(t)
  const originalWrite = fs.writeFile
  t.mock.method(console, 'error', () => {})
  const mocked = t.mock.method(fs, 'writeFile', (file, ...args) => {
    if (file.endsWith('.pending')) { process.nextTick(() => args.at(-1)(Error('disk full'))); return }
    return originalWrite(file, ...args)
  })
  store.addImage(img, Buffer.from('not-saved'), 'failure')
  await delay(20)
  assert.equal(store.list().length, 0)
  assert.equal(store._pendingImages.size, 0)
  mocked.mock.restore()
})

test('encoding failure uses the native PNG fallback', async t => {
  const { store } = fixture(t)
  t.mock.method(console, 'error', () => {})
  const native = { ...img, toBitmap: () => Buffer.alloc(1), toPNG: () => Buffer.from('fallback') }
  store.addImage(native, null, 'fallback')
  await settled(store)
  assert.equal(fs.readFileSync(store.list()[0].file, 'utf8'), 'fallback')
})
test('deletion while an image is being encoded does not save it later', async t => {
  const { store } = fixture(t)
  const native = { ...img, toBitmap: () => Buffer.alloc(4000*100*4), toPNG: () => { throw Error('unexpected fallback') } }
  store.addImage(native, null, 'cancelled')
  const item = store.list()[0]
  store.remove(item.id)
  await delay(100)
  assert.equal(fs.existsSync(item.file), false)
  assert.equal(store.list().length, 0)
})
