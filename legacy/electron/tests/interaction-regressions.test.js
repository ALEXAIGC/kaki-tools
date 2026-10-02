const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const vm = require('node:vm')
const Store = require('../main/store')

test('copying identical text replaces or removes its old formatting', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaki-rich-'))
  const store = new Store(dir)
  try {
    store.addText('same', { html: '<b>same</b>', rtf: 'old' })
    store.addText('same', { html: '<i>same</i>' })
    assert.equal(store.list().length, 1)
    assert.equal(store.list()[0].html, '<i>same</i>')
    assert.equal(store.list()[0].rtf, undefined)
    store.addText('different')
    store.addText('same')
    assert.equal(store.list()[0].html, undefined)
    store.flushSync()
    assert.equal(new Store(dir).list()[0].html, undefined)
  } finally { clearTimeout(store._flushTimer); await new Promise(resolve => setTimeout(resolve, 30)); await fs.promises.rm(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 20 }) }
})

test('window arrangement keeps the captured application and checks focus before resizing', () => {
  const calls = [], logs = []
  const mockElectron = { app: {}, Notification: class {}, screen: {
    getDisplayMatching: () => ({workArea:{x:0,y:25,width:1200,height:800}}),
  } }
  const context = { module:{exports:{}}, process:{platform:'darwin'}, setTimeout,
    require: name => name === 'electron' ? mockElectron : name === './log' ? {log:(...args)=>logs.push(args)} : name === 'child_process' ? {
      execFile: (file,args,opts,cb) => { calls.push(args[1]); cb(null,calls.length===1 ? '123|0|25|800|600' : 'STALE') },
    } : require(name) }
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../main/winman.js'),'utf8'),context)
  context.module.exports.arrange('left-half')
  assert.equal(calls.length,2)
  assert.match(calls[1],/unix id is 123/)
  assert.match(calls[1],/if frontmost of p is false then return "STALE"/)
  assert.match(calls[1],/set size of win to \{600, 800\}/)
  assert.ok(logs.some(args=>args[0].includes('排列取消')))
})

test('native clipboard changes capture new formatting even when text stays identical', () => {
  let html = '<b>A</b>', text = 'A'
  const received = []
  const clipboard = { availableFormats:()=>html?['text/html']:[], readText:()=>text, readHTML:()=>html }
  const context = {module:{exports:{}},Date,setTimeout,clearTimeout,setInterval,clearInterval,
    require:name=>name==='electron'?{clipboard}:name==='./image-size'?require('../main/image-size'):require(name)}
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../main/watcher.js'),'utf8'),context)
  const watcher = new context.module.exports({onText:(text,rich)=>received.push({text,...rich})})
  watcher.tickFromNativeChange()
  html='<i>A</i>'; watcher.tickFromNativeChange()
  assert.equal(received[1].html,'<i>A</i>')
  html=''; watcher.tickText()
  assert.equal(received[2].html,undefined)
  text=''; watcher.tickText(); text='A'; watcher.tickText()
  assert.equal(received.length,4)
})
