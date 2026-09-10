const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const vm = require('node:vm')
const Store = require('../main/store')

test('legacy thumbnails migrate, survive reload and remain independent in boards', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaki-resource-test-'))
  fs.mkdirSync(path.join(dir, 'images'))
  const file = path.join(dir, 'images', 'old.png')
  fs.writeFileSync(file, 'original')
  fs.writeFileSync(path.join(dir, 'history.json'), JSON.stringify({ boards: ['saved'], items: [
    { id: 'old', type: 'image', file, thumb: 'data:image/png;base64,YQ==', hash: 'h' },
  ] }))
  const store = new Store(dir)
  assert.equal(store.get('old').thumb, undefined)
  assert.equal(await store.getThumbnail('old'), 'data:image/png;base64,YQ==')
  store.addToBoard('old', 'saved')
  const clone = store.list().find(item => item.board)
  store.remove('old')
  store.flushSync()
  assert.equal(await new Store(dir).getThumbnail(clone.id), 'data:image/png;base64,YQ==')
  assert.equal(fs.readFileSync(clone.file, 'utf8'), 'original')
  store.addImage({ resize: () => ({ toDataURL: () => 'new-thumb' }), getSize: () => ({width:1,height:1}) }, Buffer.from('new'), 'new')
  assert.equal(store.list()[0].thumb, undefined)
  assert.equal(await store.getThumbnail(store.list()[0].id), 'new-thumb')
  store.flushSync()
})

test('failed history writes back off, stop retrying and recover on a new change', () => {
  let fail = true, writes = 0
  const timers = []
  const mockFs = {
    mkdirSync() {}, existsSync: () => false,
    readFileSync() { throw Error('missing') },
    writeFile(_p, _data, cb) { writes++; cb(fail ? Error('disk full') : null) },
    unlink(_p, cb) { cb() }, rename(_a, _b, cb) { cb(null) },
  }
  const context = { module: {exports:{}}, require: name => name === 'fs' ? mockFs : require(name),
    process, console: {error(){},warn(){}}, Date,
    clearTimeout() {}, setTimeout(fn, ms) { timers.push({fn,ms}); return timers.length },
  }
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../main/store.js'), 'utf8'), context)
  const store = new context.module.exports('/test')
  store._revision = 1
  store.flush()
  assert.equal(writes, 1)
  assert.equal(timers[0].ms >= 900, true)
  for (let i=0;i<5;i++) timers[i].fn()
  assert.equal(writes, 6)
  assert.equal(timers.length, 5)
  assert.equal(store._savedRevision, 0)
  fail = false
  store.persist()
  timers[5].fn()
  assert.equal(store._savedRevision, store._revision)
  assert.equal(store._writeFailures, 0)
})

test('thumbnail write failure preserves embedded data', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaki-thumbnail-failure-'))
  fs.mkdirSync(path.join(dir, 'images', 'old.png.thumb'), {recursive:true})
  fs.writeFileSync(path.join(dir, 'history.json'), JSON.stringify({items:[
    {id:'old', type:'image', file:'old.png', thumb:'preserved-thumbnail'},
  ]}))
  const store = new Store(dir)
  assert.equal(store.get('old').thumb, 'preserved-thumbnail')
  assert.equal(await store.getThumbnail('old'), 'preserved-thumbnail')
})

test('Deskflow escalates only when a process has not exited', () => {
  let timer, exitHandler, kills = []
  const child = { killed: false, exitCode: null, signalCode: null,
    kill(signal) { this.killed=true; kills.push(signal) }, once(_event, cb) {exitHandler=cb} }
  const source = fs.readFileSync(path.join(__dirname, '../main/deskflow.js'), 'utf8')
  const method = source.slice(source.lastIndexOf('  stop() {'), source.lastIndexOf('\n}\n'))
  const context = {setTimeout(fn) {timer=fn; return {unref(){}}}, clearTimeout(){timer=null}}
  const object = vm.runInNewContext('({' + method + '})', context)
  object.child=child
  object.stop()
  timer()
  assert.deepEqual(kills, ['SIGTERM','SIGKILL'])
  exitHandler()
  assert.equal(timer,null)
  kills=[]; child.exitCode=0; object.child=child; object.stop()
  assert.deepEqual(kills,[])
})
