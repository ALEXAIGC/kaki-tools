const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')

function loggerHarness(initialBytes = 0) {
  const filename = '/isolated/kaki.log'
  const files = new Map()
  if (initialBytes) files.set(filename, Buffer.alloc(initialBytes, 120))
  const pending = [], syncWrites = [], rotations = [], stderr = []
  const timers = new Map()
  const missing = () => Object.assign(Error('missing'), { code: 'ENOENT' })
  const append = (file, data) => files.set(file, Buffer.concat([files.get(file) || Buffer.alloc(0), data]))
  const mockFs = {
    statSync(file) { if (!files.has(file)) throw missing(); return { size: files.get(file).length } },
    renameSync(from, to) {
      if (!files.has(from)) throw missing()
      rotations.push([from, to])
      files.set(to, files.get(from)); files.delete(from)
    },
    appendFile(file, data, _options, callback) { pending.push({ file, data, callback }) },
    appendFileSync(file, data) { syncWrites.push({ file, data }); append(file, data) },
  }
  const context = {
    module: { exports: {} }, Buffer, Date,
    require: name => name === 'fs' ? mockFs : require(name),
    process: { stderr: { write: text => stderr.push(text) } },
    setTimeout(fn) { const id = { unref() {} }; timers.set(id, fn); return id },
    clearTimeout(id) { timers.delete(id) },
  }
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../main/log.js'), 'utf8'), context)
  const logger = context.module.exports
  const runTimer = () => {
    const [id, fn] = timers.entries().next().value || []
    assert.ok(fn, 'a batch should be scheduled')
    timers.delete(id); fn()
  }
  const completeAppend = error => {
    const job = pending.shift()
    assert.ok(job)
    if (!error) append(job.file, job.data)
    job.callback(error || null)
    return job
  }
  return { logger, filename, files, pending, syncWrites, rotations, stderr, timers, runTimer, completeAppend }
}

test('file logging batches multiple messages into one asynchronous append', () => {
  const h = loggerHarness()
  h.logger.init('/isolated')
  h.logger.log('first message')
  h.logger.log('second message')
  assert.equal(h.pending.length, 0)
  assert.equal(h.timers.size, 1)
  h.runTimer()
  assert.equal(h.pending.length, 1)
  assert.equal(h.syncWrites.length, 0)
  h.completeAppend()
  const text = h.files.get(h.filename).toString()
  assert.match(text, /应用启动/)
  assert.match(text, /first message/)
  assert.match(text, /second message/)
  assert.equal(h.timers.size, 0)
})

test('a busy writer retains only a bounded batch of the most recent logs', () => {
  const h = loggerHarness()
  h.logger.init('/isolated'); h.runTimer()
  for (let i = 0; i <= 200; i++) h.logger.log(`entry-${i}|` + 'x'.repeat(8192))
  assert.equal(h.pending.length, 1)
  assert.equal(h.timers.size, 0)
  h.completeAppend(); h.runTimer()
  const batch = h.pending[0].data
  assert.ok(batch.length <= 64 * 1024)
  assert.match(batch.toString(), /entry-200\|/)
  assert.doesNotMatch(batch.toString(), /entry-1\|/)
  for (const line of batch.toString().trimEnd().split('\n')) assert.ok(Buffer.byteLength(line + '\n') <= 8 * 1024)
  h.completeAppend()
})

test('the active log rotates during a running session and retains one previous file', () => {
  const h = loggerHarness(1024 * 1024 - 2048)
  h.files.set(h.filename + '.old', Buffer.from('older backup'))
  h.logger.init('/isolated'); h.logger.log('first|' + 'a'.repeat(900)); h.runTimer(); h.completeAppend()
  assert.equal(h.rotations.length, 0)
  const previous = h.files.get(h.filename)
  h.logger.log('latest|' + 'b'.repeat(4096)); h.runTimer(); h.completeAppend()
  assert.equal(h.rotations.length, 1)
  assert.deepEqual(h.files.get(h.filename + '.old'), previous)
  assert.match(h.files.get(h.filename).toString(), /latest\|/)
  assert.equal(h.files.size, 2)
  assert.ok(h.files.get(h.filename).length <= 1024 * 1024)
})

test('a failed append is dropped without retry floods and later messages can be written', () => {
  const h = loggerHarness()
  h.logger.init('/isolated'); h.logger.log('failed batch'); h.runTimer()
  h.completeAppend(Error('disk full'))
  assert.equal(h.pending.length, 0)
  assert.equal(h.timers.size, 0)
  h.logger.log('recovered batch'); h.runTimer(); h.completeAppend()
  assert.match(h.files.get(h.filename).toString(), /recovered batch/)
  assert.doesNotMatch(h.files.get(h.filename).toString(), /failed batch/)
})

test('exit flush saves queued messages without replaying the asynchronous batch', () => {
  const h = loggerHarness()
  h.logger.init('/isolated'); h.logger.log('in flight'); h.runTimer()
  h.logger.log('exit tail'); h.logger.flushSync()
  assert.equal(h.syncWrites.length, 1)
  assert.match(h.syncWrites[0].data.toString(), /exit tail/)
  assert.doesNotMatch(h.syncWrites[0].data.toString(), /in flight/)
  h.completeAppend()
  const text = h.files.get(h.filename).toString()
  assert.equal(text.split('in flight').length - 1, 1)
  assert.equal(text.split('exit tail').length - 1, 1)
  h.logger.flushSync()
  assert.equal(h.syncWrites.length, 1)
  assert.equal(h.timers.size, 0)
})

test('formatting failures and large multibyte messages cannot crash or exceed the line limit', () => {
  const h = loggerHarness()
  h.logger.init('/isolated')
  const circular = {}; circular.self = circular
  const unprintable = { toJSON() { throw Error('json') }, toString() { throw Error('string') } }
  assert.doesNotThrow(() => h.logger.log(circular, 10n, unprintable))
  h.logger.log('汉字😀'.repeat(5000), 'a\nb')
  h.runTimer(); h.completeAppend()
  const text = h.files.get(h.filename).toString()
  assert.match(text, /无法序列化/)
  assert.match(text, /截断/)
  assert.doesNotMatch(text, /\uFFFD/)
  for (const line of text.trimEnd().split('\n')) assert.ok(Buffer.byteLength(line + '\n') <= 8 * 1024)
})
