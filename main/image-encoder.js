const { Worker } = require('node:worker_threads')
const path = require('node:path')
// 一次只提交一张原图，避免工作线程消息队列累积多份大位图。
let worker = null, active = null, idleTimer = null, jobTimer = null
const queue = []
function retire() {
  const previous = worker
  worker = null
  if (previous) previous.terminate().catch(() => {})
}
function finish(error, png) {
  clearTimeout(jobTimer)
  jobTimer = null
  const job = active
  active = null
  if (job) {
    if (error) job.reject(error)
    else job.resolve(png && Buffer.from(png))
  }
  drain()
}
function drain() {
  if (active) return
  clearTimeout(idleTimer)
  while (queue.length && queue[0].cancelled()) queue.shift().resolve(null)
  if (!queue.length) {
    if (worker) {
      worker.unref()
      idleTimer = setTimeout(retire, 30000)
      idleTimer.unref()
    }
    return
  }
  active = queue.shift()
  try {
    if (!worker) {
      const next = new Worker(path.join(__dirname, 'image-encode-worker.js'))
      worker = next
      next.on('message', message => {
        if (worker === next) finish(message.error ? Error(message.error) : null, message.png)
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
    const { width, height } = active.img.getSize()
    const bitmap = active.img.toBitmap()
    if (bitmap.length !== width * height * 4) throw Error('Unexpected native bitmap size')
    worker.postMessage({ bitmap, width, height })
    jobTimer = setTimeout(() => { retire(); finish(Error('Image encoding timed out')) }, 30000)
  } catch (error) { retire(); finish(error) }
}
function encodeImage(img, cancelled = () => false) {
  return new Promise((resolve, reject) => {
    queue.push({ img, cancelled, resolve, reject })
    drain()
  })
}
module.exports = { encodeImage }
