const { Worker, isMarkedAsUntransferable } = require('node:worker_threads')
const path = require('node:path')

// Keep 8K captures at their original resolution. Reserve both the native image and
// its transferable bitmap for every queued job; PNG/compression workspace is extra.
const MAX_IMAGE_PIXELS = 40_000_000
const MAX_IMAGE_BYTES = 160 * 1024 * 1024
const MAX_QUEUE_BYTES = 384 * 1024 * 1024
let worker = null, active = null, idleTimer = null, jobTimer = null, reservedBytes = 0
const queue = []

function imageError(code, message) { return Object.assign(Error(message), { code }) }
function validateImageSize(img, png) {
  const { width, height } = img.getSize()
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width < 1 || height < 1) {
    throw imageError('INVALID_IMAGE_SIZE', '图片尺寸无效')
  }
  const pixels = width * height, bytes = pixels * 4
  if (!Number.isSafeInteger(bytes) || pixels > MAX_IMAGE_PIXELS || bytes > MAX_IMAGE_BYTES || (png && png.length > MAX_IMAGE_BYTES)) {
    throw imageError('IMAGE_TOO_LARGE', '图片超过 4000 万像素或 160 MiB，未加入历史')
  }
  return { width, height, bytes }
}
function retire() {
  clearTimeout(idleTimer)
  idleTimer = null
  const previous = worker
  worker = null
  if (previous) previous.terminate().catch(() => {})
}
function settle(job, error, png) {
  job.img = null
  reservedBytes -= job.reservation
  if (job.signal) job.signal.removeEventListener('abort', job.abort)
  if (error) job.reject(error)
  else job.resolve(png)
}
function finish(error, png) {
  clearTimeout(jobTimer)
  jobTimer = null
  const job = active
  active = null
  if (job) settle(job, error, png)
  drain()
}
function cancel(job) {
  if (active === job) { retire(); finish(null, null); return }
  const index = queue.indexOf(job)
  if (index < 0) return
  queue.splice(index, 1)
  settle(job, null, null)
  drain()
}
function drain() {
  if (active) return
  clearTimeout(idleTimer)
  idleTimer = null
  while (queue.length && queue[0].cancelled()) settle(queue.shift(), null, null)
  if (!queue.length) {
    if (worker) {
      worker.unref()
      idleTimer = setTimeout(retire, 30000)
      idleTimer.unref()
    }
    return
  }
  const job = active = queue.shift()
  try {
    if (!worker) {
      const next = new Worker(path.join(__dirname, 'image-encode-worker.js'))
      worker = next
      next.on('message', message => {
        if (worker !== next) return
        if (message.error) return finish(imageError(message.code, message.error))
        const data = message.png
        if (!data || !data.byteLength) return finish(Error('Image worker returned no PNG'))
        if (data.byteLength > MAX_IMAGE_BYTES) return finish(imageError('IMAGE_TOO_LARGE', '编码图片超过 160 MiB'))
        // The worker transfers an owned ArrayBuffer; this view does not copy its PNG.
        const png = ArrayBuffer.isView(data)
          ? Buffer.from(data.buffer, data.byteOffset, data.byteLength) : Buffer.from(data)
        finish(null, png)
      })
      const failed = error => {
        if (worker !== next) return
        retire()
        finish(error)
      }
      next.on('error', failed)
      next.on('exit', code => failed(Error(`Image worker exited: ${code}`)))
    }
    worker.ref()
    const bitmap = job.img.toBitmap()
    if (bitmap.length !== job.bytes) throw Error('Unexpected native bitmap size')
    // Native/pooled buffers are not reliably transferable. An exact, owned buffer
    // prevents cloning an entire backing pool and crosses the worker boundary once.
    const ownsBuffer = bitmap.byteOffset === 0 && bitmap.byteLength === bitmap.buffer.byteLength
      && !isMarkedAsUntransferable?.(bitmap.buffer)
    const transferable = ownsBuffer ? bitmap.buffer
      : bitmap.buffer.slice(bitmap.byteOffset, bitmap.byteOffset + bitmap.byteLength)
    worker.postMessage({ bitmap: transferable, width: job.width, height: job.height }, [transferable])
    job.img = null
    jobTimer = setTimeout(() => {
      if (active !== job) return
      retire()
      finish(Error('Image encoding timed out'))
    }, 30000)
  } catch (error) { retire(); finish(error) }
}
// Existing cancellation callbacks remain supported; AbortSignal also releases a
// queued image immediately instead of waiting for the active PNG to finish.
function encodeImage(img, options = {}) {
  return new Promise((resolve, reject) => {
    const signal = typeof options === 'function' ? null : options.signal
    const cancelled = typeof options === 'function' ? options : () => !!signal?.aborted
    if (cancelled()) { resolve(null); return }
    const size = validateImageSize(img)
    const reservation = size.bytes * 2
    if (reservedBytes + reservation > MAX_QUEUE_BYTES) {
      reject(imageError('IMAGE_QUEUE_FULL', '图片处理队列已达到 384 MiB 预算，未加入历史'))
      return
    }
    const job = { ...size, img, reservation, cancelled, signal, resolve, reject }
    job.abort = () => cancel(job)
    reservedBytes += reservation
    queue.push(job)
    if (signal) signal.addEventListener('abort', job.abort, { once: true })
    drain()
  })
}
module.exports = { encodeImage, validateImageSize, MAX_IMAGE_BYTES, MAX_QUEUE_BYTES }
