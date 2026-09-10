const { app, BrowserWindow } = require('electron')
const fs = require('node:fs')
const assert = require('node:assert/strict')
const { execFileSync } = require('node:child_process')
const path = require('node:path')
const os = require('node:os')
const root = path.resolve(__dirname, '..')
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'kaki-render-check-'))
const htmlFile = path.join(temp, 'index.html')
const html = fs.readFileSync(root + '/renderer/index.html', 'utf8').replace(/<script[^>]*>[\s\S]*?<\/script>/g, '').replace(/<meta http-equiv="Content-Security-Policy"[^>]*>/, '').replace('href="style.css"', `href="file://${root}/renderer/style.css"`)
fs.writeFileSync(htmlFile, html)
const mock = `window.matchMedia = () => ({matches:false,addEventListener(){}}); window.lucide={createIcons(){}}; window.captured=[]; window.intervals=[]; window.setInterval=fn=>intervals.push(fn); window.kaki=new Proxy({ getHistory:()=>new Promise(()=>{}), getThumbnail:async()=>'', diagnostic:()=>{}, activate:id=>captured.push(id) },{get:(o,k)=>o[k]||(()=>{})});`
const data = Array.from({length:500}, (_,i)=>({id:'item-'+i,type:'text',text:'Record '+i,chars:8,createdAt:Date.now()-60000*i,tags:[],note:'',pinned:false}))
async function run(source, changed) {
  const win = new BrowserWindow({show:false, width:1200,height:400,webPreferences:{contextIsolation:true,nodeIntegration:false}})
  await win.loadFile(htmlFile)
  await win.webContents.executeJavaScript(mock + '\n' + source)
  await win.webContents.executeJavaScript(`applyData(${JSON.stringify({items:data,boards:[]})}); window.originalCard=cardsEl.children[0];`)
  const result = await win.webContents.executeJavaScript(`(() => {
    const timings=[];
    for(let i=0;i<40;i++){const start=performance.now(); render(); timings.push(performance.now()-start)}
    const stable = originalCard === cardsEl.children[0];
    const sorted=timings.sort((a,b)=>a-b);
    const before = cardsEl.children[0]; intervals.at(-1)(); const timeStable=before===cardsEl.children[0];
    const moved = [items[1], items[0], ...items.slice(2)]; applyData({items:moved,boards:[]});
    const movedStable=cardsEl.children[1]===originalCard;
    cardsEl.children[1].onmouseenter(); const selected=sel;
    cardsEl.children[1].click();
    query='Record 0'; render(); const searchCount=cardsEl.children.length;
    query=''; render();
    const updated=items.map(i=>i.id==='item-0'?{...i,note:'updated note',pinned:true}:i);applyData({items:updated,boards:[]});
    const metadata=cardsEl.children[1].querySelector('.card-note')?.textContent;
    return {medianMs:sorted[20],p95Ms:sorted[38],stable,timeStable,movedStable,selected,activated:captured[0],searchCount,metadata};
  })()`)
  if(changed){assert.equal(result.stable,true);assert.equal(result.timeStable,true);assert.equal(result.movedStable,true);assert.equal(result.selected,1);assert.equal(result.activated,'item-0');assert.equal(result.searchCount,1);assert.equal(result.metadata,'updated note')}
  win.destroy(); return result
}
app.on('window-all-closed', () => {});
app.whenReady().then(async()=>{try{
 const baseline=execFileSync('git',['show','HEAD:renderer/app.js'],{cwd:root,encoding:'utf8'});
 console.log(JSON.stringify({baseline:await run(baseline,false),optimized:await run(fs.readFileSync(root+'/renderer/app.js','utf8'),true)}));fs.rmSync(temp,{recursive:true,force:true});app.exit(0)
}catch(e){console.error(e);app.exit(1)}})
