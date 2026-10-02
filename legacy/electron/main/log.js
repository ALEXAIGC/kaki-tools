// 文件日志批量写入；主进程只保留有界的近期诊断，退出时补齐等待队列。
const fs = require('fs')
const path = require('path')

const MAX_QUEUE_BYTES = 64 * 1024
const MAX_LINE_BYTES = 8 * 1024
const MAX_FILE_BYTES = 1024 * 1024
const FLUSH_DELAY_MS = 100
let file = null
let fileBytes = 0
let queue = []
let queuedBytes = 0
let timer = null
let writing = false

function init(dir) {
  flushSync()
  file = path.join(dir, 'kaki.log')
  try { fileBytes = fs.statSync(file).size } catch { fileBytes = 0 }
  log('===== 应用启动 =====')
}

function formatValue(value) {
  if (typeof value === 'string') return value
  try { return JSON.stringify(value) ?? String(value) } catch {
    try { return String(value) } catch { return '[无法序列化]' }
  }
}

function log(...args) {
  const timestamp = new Date().toLocaleString('zh-CN', { hour12: false })
  const body = args.map(formatValue).join(' ').replace(/[\r\n]/g, '\\n')
  let line = Buffer.from(`[${timestamp}] ${body}\n`)
  if (line.length > MAX_LINE_BYTES) {
    const suffix = Buffer.from(' …[截断]\n')
    // 截断不能留下半个 UTF-8 字符。
    const prefix = line.subarray(0, MAX_LINE_BYTES - suffix.length).toString('utf8').replace(/\uFFFD$/, '')
    line = Buffer.concat([Buffer.from(prefix), suffix])
  }
  process.stderr.write('[kaki] ' + line.toString('utf8'))
  if (!file) return
  while (queuedBytes + line.length > MAX_QUEUE_BYTES) queuedBytes -= queue.shift().length
  queue.push(line)
  queuedBytes += line.length
  schedule()
}

function schedule() {
  if (timer || writing || !queue.length) return
  timer = setTimeout(flush, FLUSH_DELAY_MS)
  timer.unref?.()
}

function takeBatch() {
  const batch = Buffer.concat(queue, queuedBytes)
  queue = []
  queuedBytes = 0
  return batch
}

function rotateFor(bytes) {
  if (fileBytes + bytes <= MAX_FILE_BYTES) return
  try { fs.renameSync(file, file + '.old') } catch (error) {
    if (error.code !== 'ENOENT') throw error
  }
  fileBytes = 0
}

function flush() {
  clearTimeout(timer)
  timer = null
  if (writing || !file || !queue.length) return
  const batch = takeBatch()
  try { rotateFor(batch.length) } catch { return }
  writing = true
  const destination = file
  fileBytes += batch.length
  const finish = error => {
    writing = false
    if (error && file === destination) {
      try { fileBytes = fs.statSync(file).size } catch { fileBytes = 0 }
    }
    // 失败批次不重复重试；之后的新诊断仍可正常保存。
    schedule()
  }
  try { fs.appendFile(destination, batch, { mode: 0o600 }, finish) } catch (error) { finish(error) }
}

function flushSync() {
  clearTimeout(timer)
  timer = null
  if (!file || !queue.length) return
  const batch = takeBatch()
  try {
    // 在途 append 不回放，也不移动它的目标文件；最多暂时多出一个有界批次。
    if (!writing) rotateFor(batch.length)
    fs.appendFileSync(file, batch, { mode: 0o600 })
    fileBytes += batch.length
  } catch {}
}

module.exports = { init, log, flushSync }
