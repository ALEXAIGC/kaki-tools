const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const { EventEmitter } = require('node:events')

// Exercise the public queue with a worker that can stay busy, fail or deliver late messages.
function fixture() {
  const workers = []
  class Worker extends EventEmitter {
    constructor() { super(); this.messages = []; workers.push(this) }
    postMessage(message, transfer) {
      this.messages.push({ message: structuredClone(message, { transfer }), transfer })
    }
    ref() {}
    unref() {}
    terminate() { this.terminated = true; return Promise.resolve() }
    complete(value = 'encoded') { this.emit('message', { png: Buffer.from(value) }) }
  }
  const context = {
    module: { exports: {} }, Buffer, ArrayBuffer, Uint8Array, __dirname: path.join(__dirname, '../main'),
    require: name => name === 'node:worker_threads' ? { Worker } : require(name),
    setTimeout: () => ({ unref() {} }), clearTimeout() {},
  }
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../main/image-encoder.js'), 'utf8'), context)
  return { encodeImage: context.module.exports.encodeImage, workers }
}
function image(width = 1, height = 1) {
  let reads = 0
  return { getSize: () => ({ width, height }),
    toBitmap() { reads++; return Buffer.alloc(width * height * 4) }, get reads() { return reads } }
}

test('oversized and invalid images reject before allocating a bitmap', { timeout: 1000 }, async () => {
  const { encodeImage, workers } = fixture()
  for (const native of [image(10000, 10000), image(0, 2), image(1.5, 1)]) {
    native.toBitmap = () => { throw Error('bitmap must not be allocated') }
    await assert.rejects(encodeImage(native), error => error.code === 'IMAGE_TOO_LARGE' || error.code === 'INVALID_IMAGE_SIZE')
    assert.equal(native.reads, 0)
  }
  assert.equal(workers.length, 0)
})

test('cancelled queued images settle immediately and return their memory reservation', { timeout: 1000 }, async () => {
  const { encodeImage, workers } = fixture()
  const first = encodeImage(image())
  const queued = image(8000, 4000) // 122 MiB native data, with room reserved for its worker bitmap.
  const controller = new AbortController()
  const cancelled = encodeImage(queued, { signal: controller.signal })
  await assert.rejects(encodeImage(image(8000, 4000)), error => error.code === 'IMAGE_QUEUE_FULL')
  controller.abort()
  assert.equal(await cancelled, null)
  assert.equal(queued.reads, 0)
  const replacement = image(8000, 4000)
  const replacementController = new AbortController()
  const next = encodeImage(replacement, { signal: replacementController.signal })
  replacementController.abort()
  assert.equal(await next, null)
  assert.equal(replacement.reads, 0)
  workers[0].complete()
  assert.equal((await first).toString(), 'encoded')
})

test('cancelling active encoding terminates its worker and ignores late output', { timeout: 1000 }, async () => {
  const { encodeImage, workers } = fixture()
  const controller = new AbortController()
  const cancelled = encodeImage(image(), { signal: controller.signal })
  const next = encodeImage(image())
  controller.abort()
  assert.equal(await cancelled, null)
  assert.equal(workers[0].terminated, true)
  assert.equal(workers.length, 2)
  workers[0].complete('stale')
  workers[1].complete('current')
  assert.equal((await next).toString(), 'current')
})

test('a worker crash releases the failed job and starts the next queued image', { timeout: 1000 }, async () => {
  const { encodeImage, workers } = fixture()
  const first = encodeImage(image())
  const next = encodeImage(image())
  workers[0].emit('error', Error('worker failed'))
  await assert.rejects(first, /worker failed/)
  assert.equal(workers[0].terminated, true)
  assert.equal(workers.length, 2)
  workers[0].complete('stale')
  workers[1].complete('recovered')
  assert.equal((await next).toString(), 'recovered')
})

test('worker receives an owned transferred bitmap, preserving the native source', { timeout: 1000 }, async () => {
  const { encodeImage, workers } = fixture()
  const source = Buffer.from([1, 2, 3, 4])
  const encoded = encodeImage({ getSize: () => ({ width: 1, height: 1 }), toBitmap: () => source })
  const sent = workers[0].messages[0]
  assert.equal(sent.transfer.length, 1)
  assert.equal(sent.transfer[0].byteLength, 0)
  assert.deepEqual([...new Uint8Array(sent.message.bitmap)], [1, 2, 3, 4])
  assert.deepEqual([...source], [1, 2, 3, 4])
  workers[0].complete()
  await encoded
})

test('legacy cancellation callbacks still skip a queued image before encoding', { timeout: 1000 }, async () => {
  const { encodeImage, workers } = fixture()
  const first = encodeImage(image())
  let cancelled = false
  const native = image()
  const next = encodeImage(native, () => cancelled)
  cancelled = true
  workers[0].complete()
  await first
  assert.equal(await next, null)
  assert.equal(native.reads, 0)
})


test('an 8K screenshot is admitted at full resolution without allocating while queued', { timeout: 1000 }, async () => {
  const { encodeImage, workers } = fixture()
  const first = encodeImage(image())
  const native = image(7680, 4320)
  const controller = new AbortController()
  const next = encodeImage(native, { signal: controller.signal })
  controller.abort()
  assert.equal(await next, null)
  assert.equal(native.reads, 0)
  workers[0].complete()
  await first
})

test('an already aborted capture never allocates a bitmap or starts a worker', { timeout: 1000 }, async () => {
  const { encodeImage, workers } = fixture()
  const native = image()
  const controller = new AbortController()
  controller.abort()
  assert.equal(await encodeImage(native, { signal: controller.signal }), null)
  assert.equal(native.reads, 0)
  assert.equal(workers.length, 0)
})
