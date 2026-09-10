const { parentPort } = require('node:worker_threads')
const { PNG } = require('pngjs')
parentPort.on('message', ({ bitmap, width, height }) => {
  try {
    const data = Buffer.from(bitmap.buffer, bitmap.byteOffset, bitmap.byteLength)
    if (data.length !== width * height * 4) throw Error('Unexpected native bitmap size')
    // Electron/Skia 位图为预乘 alpha 的 BGRA；PNG 使用非预乘 RGBA。
    for (let i = 0; i < data.length; i += 4) {
      const blue = data[i], green = data[i + 1], red = data[i + 2], alpha = data[i + 3]
      const scale = alpha ? 255 / alpha : 0
      data[i] = Math.min(255, Math.round(red * scale))
      data[i + 1] = Math.min(255, Math.round(green * scale))
      data[i + 2] = Math.min(255, Math.round(blue * scale))
    }
    const png = PNG.sync.write({ width, height, data }, { deflateLevel: 6 })
    parentPort.postMessage({ png })
  } catch (error) { parentPort.postMessage({ error: error.message }) }
})
