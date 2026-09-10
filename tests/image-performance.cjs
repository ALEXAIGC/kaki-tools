const { app, nativeImage } = require('electron')
const assert = require('node:assert/strict')
const root = require('node:path').resolve(__dirname, '..')
const { PNG } = require(root+'/node_modules/pngjs')
const { encodeImage } = require(root+'/main/image-encoder')
app.whenReady().then(async()=>{try{
 const width=3840,height=2160,bitmap=Buffer.alloc(width*height*4)
 for(let i=0;i<bitmap.length;i+=4){const a=(i/4)%256;bitmap[i]=Math.round(0.2*a);bitmap[i+1]=Math.round(0.4*a);bitmap[i+2]=Math.round(0.8*a);bitmap[i+3]=a}
 const img=nativeImage.createFromBitmap(bitmap,{width,height})
 let start=performance.now();const baseline=img.toPNG();const syncBlockMs=performance.now()-start
 let beats=0;const timer=setInterval(()=>beats++,5)
 start=performance.now();const promise=encodeImage(img);const dispatchBlockMs=performance.now()-start
 const png=await promise;const workerTotalMs=performance.now()-start;clearInterval(timer)
 const expected=PNG.sync.read(baseline),actual=PNG.sync.read(png)
 assert.equal(actual.width,width);assert.equal(actual.height,height)
 let maxChannelDifference=0
 for(let i=0;i<expected.data.length;i++)maxChannelDifference=Math.max(maxChannelDifference,Math.abs(expected.data[i]-actual.data[i]))
 assert.ok(maxChannelDifference<=1, 'PNG color mismatch: '+maxChannelDifference)
 assert.ok(beats>0,'main loop did not progress')
 console.log(JSON.stringify({syncBlockMs,dispatchBlockMs,workerTotalMs,mainLoopTicks:beats,maxChannelDifference}));app.exit(0)
}catch(error){console.error(error);app.exit(1)}})
