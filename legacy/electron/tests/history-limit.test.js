const {test}=require('node:test')
const assert=require('node:assert/strict')
const fs=require('node:fs')
const path=require('node:path')
const os=require('node:os')
const Store=require('../main/store')
const {historyLimit}=require('../main/history-policy')

test('history limit normalizes legacy, invalid and fractional settings',()=>{
  for(const value of [500,undefined,0,-1,'bad',Infinity]) assert.equal(historyLimit(value),100)
  assert.equal(historyLimit(40),40)
  assert.equal(historyLimit(12.8),12)
})

test('startup trims legacy history to 100, preserves pinned/boards and removes overflow image files',async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'kaki-limit-'))
  const imageDir=path.join(dir,'images');fs.mkdirSync(imageDir)
  const oldImage=path.join(imageDir,'old.png');fs.writeFileSync(oldImage,'old');fs.writeFileSync(oldImage+'.thumb','old preview')
  const items=Array.from({length:120},(_,i)=>({id:'text-'+i,type:'text',text:'value '+i,createdAt:120-i}))
  items.push({id:'old-image',type:'image',file:oldImage},{id:'pin',type:'text',text:'saved',pinned:true},{id:'board',type:'text',text:'favorite',board:'saved'})
  fs.writeFileSync(path.join(dir,'history.json'),JSON.stringify({items,boards:['saved']}))
  const store=new Store(dir,{maxHistoryItems:500})
  try {
    assert.equal(store.list().filter(i=>!i.board&&!i.pinned).length,100)
    assert.equal(store.list()[0].id,'text-0')
    assert.equal(store.list()[99].id,'text-99')
    assert.ok(store.get('pin'));assert.ok(store.get('board'))
    assert.equal(fs.existsSync(oldImage),false);assert.equal(fs.existsSync(oldImage+'.thumb'),false)
    store.flushSync()
    assert.equal(new Store(dir).list().length,102)
    store.togglePin('pin')
    assert.equal(store.list().filter(i=>!i.board&&!i.pinned).length,100)
  } finally {
    clearTimeout(store._flushTimer)
    await new Promise(resolve=>setTimeout(resolve,30))
    await fs.promises.rm(dir,{recursive:true,force:true,maxRetries:3,retryDelay:20})
  }
})
