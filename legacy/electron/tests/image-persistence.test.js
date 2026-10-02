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

test('pending PNG writes retain only the encoded bytes, and deletion releases them', async t => {
  const { store } = fixture(t)
  store.addImage(img, Buffer.from('provided'), 'provided')
  const item = store.list()[0]
  const pending = store._pendingImages.get(item.id)
  assert.equal(pending.img, null)
  store.remove(item.id)
  assert.equal(pending.png, null)
  assert.equal(pending.img, null)
  await delay(30)
  assert.equal(fs.existsSync(item.file), false)
})

test('synchronous image completion cancels encoding and releases all native image references', async t => {
  const { store } = fixture(t)
  const native = { ...img, toBitmap: () => Buffer.alloc(4000 * 100 * 4), toPNG: () => Buffer.from('synchronous') }
  store.addImage(native, null, 'synchronous')
  const item = store.list()[0]
  const pending = store._pendingImages.get(item.id)
  store.get(item.id)
  assert.equal(pending.img, null)
  assert.equal(pending.png, null)
  assert.equal(pending.controller.signal.aborted, true)
  assert.equal(store._pendingImages.size, 0)
  await delay(30)
  assert.equal(fs.readFileSync(item.file, 'utf8'), 'synchronous')
})

test('history trimming releases pending native data instead of waiting for the worker', async t => {
  const { store } = fixture(t)
  store.maxHistoryItems = 1
  const native = { ...img, toBitmap: () => Buffer.alloc(4000 * 100 * 4), toPNG: () => { throw Error('must not encode deleted image') } }
  store.addImage(native, null, 'trimmed')
  const pending = store._pendingImages.get(store.list()[0].id)
  store.addText('new entry')
  assert.equal(pending.img, null)
  assert.equal(pending.png, null)
  assert.equal(pending.controller.signal.aborted, true)
  assert.equal(store._pendingImages.size, 0)
  await delay(30)
  assert.deepEqual(store.list().map(item => item.text), ['new entry'])
})

test('an oversized capture does not bypass the budget through synchronous PNG fallback', async t => {
  const { store } = fixture(t)
  let nativeEncodes = 0, bitmaps = 0
  t.mock.method(console, 'error', () => {})
  const native = { ...img, getSize: () => ({ width: 10000, height: 10000 }),
    resize: () => ({ toDataURL: () => 'thumbnail' }),
    toBitmap: () => { bitmaps++; throw Error('must not allocate oversized bitmap') },
    toPNG: () => { nativeEncodes++; return Buffer.from('oversized') } }
  store.addImage(native, null, 'oversized')
  await settled(store)
  assert.equal(nativeEncodes, 0)
  assert.equal(bitmaps, 0)
  assert.equal(store.list().length, 0)
})

test('a completed old history write cannot replace a newer synchronous exit snapshot', () => {
  const vm = require('node:vm')
  const files = new Map(), writes = [], renames = []
  const mockFs = { mkdirSync() {}, existsSync: file => files.has(file),
    readFileSync(file) { if (!files.has(file)) throw Error('missing'); return files.get(file) },
    writeFile(file, data, callback) { files.set(file, data); writes.push(callback) },
    rename(from, to, callback) { renames.push(() => { files.set(to, files.get(from)); files.delete(from); callback(null) }) },
    unlink(file, callback) { files.delete(file); callback() },
    writeFileSync(file, data) { files.set(file, data) },
    renameSync(from, to) { files.set(to, files.get(from)); files.delete(from) } }
  const context = { module: { exports: {} }, process, console, Date, AbortController,
    require: name => name === 'fs' ? mockFs : name.startsWith('./') ? require('../main/' + name.slice(2)) : require(name),
    setTimeout: () => ({}), clearTimeout() {} }
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../main/store.js'), 'utf8'), context)
  const store = new context.module.exports('/isolated')
  store.addText('old')
  store.flush()
  writes.shift()(null)
  store.addText('latest')
  store.flushSync()
  for (const rename of renames) rename()
  assert.deepEqual(JSON.parse(files.get(store.file)).items.map(item => item.text), ['latest', 'old'])
  assert.equal(store._savedRevision, store._revision)
})


test('native worker-failure fallback still enforces the encoded byte limit', async t => {
  const { store } = fixture(t)
  const errors = []
  store.onImageError = error => errors.push(error.code)
  t.mock.method(console, 'error', () => {})
  const native = { ...img, toBitmap: () => { throw Error('worker cannot read bitmap') },
    toPNG: () => ({ length: 160 * 1024 * 1024 + 1 }) }
  store.addImage(native, null, 'oversized-fallback')
  await settled(store)
  assert.equal(store.list().length, 0)
  assert.deepEqual(errors, ['IMAGE_TOO_LARGE'])
})


test('oversized synchronous completion removes the image without aborting the rest of the exit flush', async t => {
  const { store, dir } = fixture(t)
  const errors = []
  store.onImageError = error => errors.push(error.code)
  t.mock.method(console, 'error', () => {})
  const native = { ...img, toBitmap: () => { throw Error('worker cannot read bitmap') },
    toPNG: () => ({ length: 160 * 1024 * 1024 + 1 }) }
  store.addText('preserve this')
  store.addImage(native, null, 'oversized-at-exit')
  store.flushSync()
  assert.deepEqual(errors, ['IMAGE_TOO_LARGE'])
  assert.deepEqual(new Store(dir).list().map(item => item.text), ['preserve this'])
  assert.equal(store._pendingImages.size, 0)
})


test('a failed pending image at exit does not prevent saving unrelated text history', async t => {
  const { store, dir } = fixture(t)
  const errors = [], callbacks = []
  store.onImageError = error => errors.push(error.code)
  t.mock.method(console, 'error', () => {})
  const writeFile = fs.writeFile, writeFileSync = fs.writeFileSync
  const asyncWrite = t.mock.method(fs, 'writeFile', (file, ...args) => {
    if (file.endsWith('.png.pending')) { callbacks.push(args.at(-1)); return }
    return writeFile(file, ...args)
  })
  const syncWrite = t.mock.method(fs, 'writeFileSync', (file, ...args) => {
    if (path.dirname(file) === store.imgDir) throw Object.assign(Error('image directory not writable'), { code: 'EACCES' })
    return writeFileSync(file, ...args)
  })
  store.addText('keep this text')
  store.addImage(img, Buffer.from('failed-image'), 'failed-at-exit')
  const image = store.list()[0]
  assert.doesNotThrow(() => store.flushSync())
  assert.equal(store._pendingImages.size, 0)
  assert.deepEqual(errors, ['EACCES'])
  assert.deepEqual(new Store(dir).list().map(item => item.text), ['keep this text'])
  assert.equal(fs.existsSync(image.file), false)
  syncWrite.mock.restore()
  asyncWrite.mock.restore()
  for (const callback of callbacks) callback(null)
})

test('a synchronous image failure preserves any already committed PNG and history record', async t => {
  const { store, dir } = fixture(t)
  const callbacks = []
  t.mock.method(console, 'error', () => {})
  const writeFile = fs.writeFile, writeFileSync = fs.writeFileSync
  const asyncWrite = t.mock.method(fs, 'writeFile', (file, ...args) => {
    if (file.endsWith('.png.pending')) { callbacks.push(args.at(-1)); return }
    return writeFile(file, ...args)
  })
  store.addImage(img, Buffer.from('pending-replacement'), 'existing-file')
  const item = store.list()[0]
  writeFileSync(item.file, Buffer.from('committed-original'))
  const syncWrite = t.mock.method(fs, 'writeFileSync', (file, ...args) => {
    if (path.dirname(file) === store.imgDir) {
      writeFileSync(file, Buffer.from('partial replacement'))
      throw Object.assign(Error('cannot finish replacement'), { code: 'ENOSPC' })
    }
    return writeFileSync(file, ...args)
  })
  assert.doesNotThrow(() => store.flushSync())
  assert.equal(store._pendingImages.size, 0)
  assert.equal(fs.readFileSync(item.file, 'utf8'), 'committed-original')
  assert.equal(new Store(dir).list()[0].id, item.id)
  syncWrite.mock.restore()
  asyncWrite.mock.restore()
  for (const callback of callbacks) callback(null)
})

test('startup removes only generated UUID PNG staging files and preserves user files', async t => {
  const { store, dir } = fixture(t)
  const id = require('node:crypto').randomUUID()
  const pending = path.join(store.imgDir, id + '.png.pending')
  const saved = path.join(store.imgDir, id + '.png')
  const ownedNames = ['user.png.pending', id + '.png.pending.copy', '00000000-0000-0000-0000-000000000000.png.pending']
  fs.writeFileSync(pending, 'orphan')
  fs.writeFileSync(saved, 'saved-png')
  for (const name of ownedNames) fs.writeFileSync(path.join(store.imgDir, name), 'user-owned')
  const directory = path.join(store.imgDir, require('node:crypto').randomUUID() + '.png.pending')
  fs.mkdirSync(directory)
  const symlink = path.join(store.imgDir, require('node:crypto').randomUUID() + '.png.pending')
  fs.symlinkSync(saved, symlink)
  new Store(dir)
  assert.equal(fs.existsSync(pending), false)
  assert.equal(fs.readFileSync(saved, 'utf8'), 'saved-png')
  for (const name of ownedNames) assert.equal(fs.readFileSync(path.join(store.imgDir, name), 'utf8'), 'user-owned')
  assert.equal(fs.statSync(directory).isDirectory(), true)
  assert.equal(fs.lstatSync(symlink).isSymbolicLink(), true)
})

test('an immediate process exit saves the image and startup cleans late temporary writes', async t => {
  const { store, dir } = fixture(t)
  const { spawnSync } = require('node:child_process')
  const childSource = `const Store = require(${JSON.stringify(path.join(__dirname, '../main/store.js'))});
    const store = new Store(process.argv[1]);
    store.addImage({ getSize: () => ({ width: 4000, height: 100 }), resize: () => ({ toDataURL: () => 'exit-preview' }) },
      Buffer.alloc(32 * 1024 * 1024, 7), 'exit');
    store.flushSync(); process.exit(0)`
  const child = spawnSync(process.execPath, ['-e', childSource, dir], { encoding: 'utf8' })
  assert.equal(child.status, 0, child.stderr)
  const loaded = new Store(dir)
  assert.equal(loaded.list().length, 1)
  const item = loaded.list()[0]
  assert.equal(fs.statSync(item.file).size, 32 * 1024 * 1024)
  assert.equal(fs.readFileSync(item.file)[0], 7)
  assert.equal(await loaded.getThumbnail(item.id), 'exit-preview')
  assert.equal(fs.readdirSync(store.imgDir).some(name => name.endsWith('.png.pending')), false)
})


test('staging cleanup preserves a capture that is still pending in this Store', async t => {
  const { store } = fixture(t)
  store.addImage(img, Buffer.from('active-image'), 'active')
  const item = store.list()[0]
  const pending = store._pendingImages.get(item.id)
  fs.writeFileSync(pending.tmp, 'active-staging')
  store.cleanupImageTemps()
  assert.equal(fs.existsSync(pending.tmp), true)
  store.remove(item.id)
  await delay(30)
  assert.equal(fs.existsSync(pending.tmp), false)
})


function blockImageWrites(t) {
  const writes = []
  const original = fs.writeFile
  t.mock.method(fs, 'writeFile', (file, ...args) => {
    if (file.endsWith('.png.pending')) { writes.push({ file, callback: args.at(-1) }); return }
    return original(file, ...args)
  })
  return writes
}

test('blocked image writes keep their raw memory reservation and reject subsequent captures', async t => {
  const { store } = fixture(t)
  const writes = blockImageWrites(t), errors = []
  store.onImageError = error => errors.push(error.code)
  t.mock.method(console, 'error', () => {})
  const large = { ...img, getSize: () => ({ width: 8000, height: 4000 }) }
  store.addImage(large, Buffer.from('first'), 'first')
  assert.equal(store._pendingImageBytes, 8000 * 4000 * 4 * 2)
  store.addImage(large, Buffer.from('second'), 'second')
  assert.deepEqual(store.list().map(item => item.hash), ['first'])
  assert.deepEqual(errors, ['IMAGE_QUEUE_FULL'])
  assert.equal(writes.length, 1)
  // Reusing an existing item needs no additional reservation.
  store.addImage(large, Buffer.from('same'), 'first')
  assert.equal(store._pendingImageBytes, 8000 * 4000 * 4 * 2)
  store.clear()
  for (const write of writes) write.callback(null)
  assert.equal(store._pendingImageBytes, 0)
})

test('provided PNG bytes also count until blocked writes finish', async t => {
  const { store } = fixture(t)
  const writes = blockImageWrites(t), errors = []
  store.onImageError = error => errors.push(error.code)
  t.mock.method(console, 'error', () => {})
  const tiny = { ...img, getSize: () => ({ width: 1, height: 1 }) }
  const png = Buffer.alloc(64 * 1024 * 1024)
  for (let index = 0; index < 7; index++) store.addImage(tiny, png, 'provided-' + index)
  assert.equal(store.list().length, 6)
  assert.equal(writes.length, 6)
  assert.equal(store._pendingImageBytes, 384 * 1024 * 1024)
  assert.deepEqual(errors, ['IMAGE_QUEUE_FULL'])
  store.clear()
  for (const write of writes) write.callback(null)
  assert.equal(store._pendingImageBytes, 0)
})

test('image write completion, deletion and synchronous completion each return the lifecycle budget', async t => {
  const { store } = fixture(t)
  const writes = blockImageWrites(t)
  const large = { ...img, getSize: () => ({ width: 8000, height: 4000 }) }
  store.addImage(large, Buffer.from('written'), 'written')
  fs.writeFileSync(writes[0].file, 'written')
  writes[0].callback(null)
  assert.equal(store._pendingImageBytes, 0)
  store.addImage(large, Buffer.from('deleted'), 'deleted')
  store.remove(store.list()[0].id)
  assert.equal(store._pendingImageBytes, 0)
  writes[1].callback(null)
  store.addImage(large, Buffer.from('sync'), 'sync')
  store.flushSync()
  assert.equal(store._pendingImageBytes, 0)
  writes[2].callback(null)
  assert.equal(fs.readFileSync(store.list()[0].file, 'utf8'), 'sync')
})

function storeWithHeldEncoder(dir, t) {
  const vm = require('node:vm')
  const encoder = require('../main/image-encoder')
  let complete
  const context = { module: { exports: {} }, process, console, Date, AbortController, setTimeout, clearTimeout,
    require: name => name === './image-encoder'
      ? { ...encoder, encodeImage: () => new Promise(resolve => { complete = resolve }) }
      : name.startsWith('./') ? require('../main/' + name.slice(2)) : require(name) }
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../main/store.js'), 'utf8'), context)
  const store = new context.module.exports(dir)
  t.after(() => { store.clear(); clearTimeout(store._flushTimer); store._flushTimer = null })
  return { store, complete: png => complete(png) }
}

test('encoded PNG growth calibrates the reservation before entering blocked disk I/O', async t => {
  const { dir } = fixture(t)
  const { store, complete } = storeWithHeldEncoder(dir, t)
  const writes = blockImageWrites(t)
  const native = { ...img, getSize: () => ({ width: 1, height: 1 }), toPNG: () => { throw Error('must not use fallback') } }
  store.addImage(native, null, 'grown')
  assert.equal(store._pendingImageBytes, 8)
  complete(Buffer.alloc(128))
  await delay(5)
  assert.equal(store._pendingImageBytes, 128)
  assert.equal(writes.length, 1)
  store.remove(store.list()[0].id)
  writes[0].callback(null)
  assert.equal(store._pendingImageBytes, 0)
  store.flushSync()
})

test('PNG growth over a full lifecycle budget is rejected without synchronous encoding fallback', async t => {
  const { dir } = fixture(t)
  const { store, complete } = storeWithHeldEncoder(dir, t)
  const writes = blockImageWrites(t), errors = []
  let fallbacks = 0
  store.onImageError = error => errors.push(error.code)
  t.mock.method(console, 'error', () => {})
  const native = { ...img, getSize: () => ({ width: 1, height: 1 }), toPNG: () => { fallbacks++; return Buffer.from('fallback') } }
  store.addImage(native, null, 'growing')
  store.addImage({ ...img, getSize: () => ({ width: 8000, height: 4000 }) }, Buffer.from('large'), 'large')
  const remainingPixels = (384 * 1024 * 1024 - 8000 * 4000 * 8 - 8) / 8
  store.addImage({ ...img, getSize: () => ({ width: remainingPixels, height: 1 }) }, Buffer.from('rest'), 'rest')
  assert.equal(store._pendingImageBytes, 384 * 1024 * 1024)
  complete(Buffer.alloc(128))
  await delay(5)
  assert.equal(fallbacks, 0)
  assert.deepEqual(errors, ['IMAGE_QUEUE_FULL'])
  assert.equal(store.list().some(item => item.hash === 'growing'), false)
  assert.equal(writes.length, 2)
  store.clear()
  for (const write of writes) write.callback(null)
  assert.equal(store._pendingImageBytes, 0)
  store.flushSync()
})


test('startup trims legacy images before writing thumbnails for retained records', async t => {
  const { dir } = fixture(t)
  const images = Array.from({ length: 101 }, (_, index) => ({
    id: 'legacy-' + index, type: 'image', file: 'legacy-' + index + '.png', thumb: 'legacy-preview',
    createdAt: 101 - index, hash: 'legacy-' + index, pinned: false,
  }))
  fs.writeFileSync(path.join(dir, 'history.json'), JSON.stringify({ items: images, boards: [] }))
  const thumbs = []
  const writeFileSync = fs.writeFileSync
  t.mock.method(fs, 'writeFileSync', (file, ...args) => {
    if (file.endsWith('.thumb')) thumbs.push(path.basename(file))
    return writeFileSync(file, ...args)
  })
  const store = new Store(dir)
  t.after(() => { clearTimeout(store._flushTimer); store._flushTimer = null })
  assert.equal(store.list().length, 100)
  assert.equal(thumbs.length, 100)
  assert.equal(thumbs.includes('legacy-100.png.thumb'), false)
  assert.equal(fs.existsSync(path.join(store.imgDir, 'legacy-100.png.thumb')), false)
  store.flushSync()
})
