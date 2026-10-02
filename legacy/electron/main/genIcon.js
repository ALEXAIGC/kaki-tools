// 运行时生成 PNG(托盘图标、测试用示例图),避免仓库里放二进制资源。
const zlib = require('zlib')

let crcTable = null
function crc32(buf) {
  if (!crcTable) {
    crcTable = []
    for (let n = 0; n < 256; n++) {
      let c = n
      for (let k = 0; k < 8; k++) c = c & 1 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1)
      crcTable[n] = c >>> 0
    }
  }
  let c = 0xFFFFFFFF
  for (const b of buf) c = crcTable[(c ^ b) & 0xFF] ^ (c >>> 8)
  return (c ^ 0xFFFFFFFF) >>> 0
}

function chunk(type, data) {
  const t = Buffer.from(type, 'ascii')
  const len = Buffer.alloc(4)
  len.writeUInt32BE(data.length)
  const crc = Buffer.alloc(4)
  crc.writeUInt32BE(crc32(Buffer.concat([t, data])))
  return Buffer.concat([len, t, data, crc])
}

// pixelFn(x, y) => [r, g, b, a]
function makePng(width, height, pixelFn) {
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0)
  ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8  // bit depth
  ihdr[9] = 6  // color type: RGBA
  const raw = Buffer.alloc(height * (1 + width * 4))
  for (let y = 0; y < height; y++) {
    const row = y * (1 + width * 4)
    raw[row] = 0 // filter: none
    for (let x = 0; x < width; x++) {
      const [r, g, b, a] = pixelFn(x, y)
      const o = row + 1 + x * 4
      raw[o] = r; raw[o + 1] = g; raw[o + 2] = b; raw[o + 3] = a
    }
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ])
}

// Kaki Tools 的「K」字 logo:三段线条(竖杠 + 上下斜杠),按距离场抗锯齿渲染,
// 任意尺寸都清晰。macOS 用黑色模板图(系统自适配深浅色),Windows 托盘用白色。
const K_SEGMENTS = [
  [0.26, 0.12, 0.26, 0.88],
  [0.78, 0.12, 0.32, 0.52],
  [0.40, 0.44, 0.80, 0.88],
]
const K_THICKNESS = 0.085

function segDist(px, py, ax, ay, bx, by) {
  const dx = bx - ax, dy = by - ay
  const t = Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
  return Math.hypot(px - (ax + t * dx), py - (ay + t * dy))
}

function makeKIconPng(size, [r, g, b]) {
  const edge = 1 / size
  return makePng(size, size, (x, y) => {
    const u = (x + 0.5) / size
    const v = (y + 0.5) / size
    let d = Infinity
    for (const [ax, ay, bx, by] of K_SEGMENTS) d = Math.min(d, segDist(u, v, ax, ay, bx, by))
    const a = Math.max(0, Math.min(1, (K_THICKNESS - d) / edge + 0.5))
    return [r, g, b, Math.round(a * 255)]
  })
}

// 应用图标(Dock / 应用程序文件夹):macOS 风格圆角方块,柿子橙渐变底 + 白色 K
// (kaki = 柿子,取品牌色)。四周留 8% 透明边距,圆角约为边长的 20%。
function roundedRectDist(u, v, x0, y0, x1, y1, radius) {
  const cx = Math.max(x0 + radius, Math.min(u, x1 - radius))
  const cy = Math.max(y0 + radius, Math.min(v, y1 - radius))
  return Math.hypot(u - cx, v - cy) - radius
}

function makeAppIconPng(size) {
  const edge = 1.5 / size
  const kScale = 0.62
  return makePng(size, size, (x, y) => {
    const u = (x + 0.5) / size
    const v = (y + 0.5) / size
    // 底板
    const bd = roundedRectDist(u, v, 0.08, 0.08, 0.92, 0.92, 0.20)
    const bgA = Math.max(0, Math.min(1, -bd / edge + 0.5))
    if (bgA <= 0) return [0, 0, 0, 0]
    // 柿子橙纵向渐变
    const r = Math.round(255 - v * 25)
    const g = Math.round(138 - v * 55)
    const b = Math.round(61 - v * 40)
    // K 字(白色),映射到中心 62% 区域
    const ku = (u - 0.53) / kScale + 0.53
    const kv = (v - 0.5) / kScale + 0.5
    let d = Infinity
    for (const [ax, ay, bx, by] of K_SEGMENTS) d = Math.min(d, segDist(ku, kv, ax, ay, bx, by))
    const kA = Math.max(0, Math.min(1, (K_THICKNESS - d) / (edge / kScale) + 0.5))
    return [
      Math.round(r + (255 - r) * kA),
      Math.round(g + (255 - g) * kA),
      Math.round(b + (255 - b) * kA),
      Math.round(bgA * 255),
    ]
  })
}

// 测试模式下的示例图片:蓝紫渐变 + 高亮斜条
function makeSamplePng(w, h) {
  return makePng(w, h, (x, y) => {
    let r = 60 + Math.round((x / w) * 120)
    let g = 80 + Math.round((y / h) * 60)
    let b = 220 - Math.round((x / w) * 60)
    if (Math.abs(x - (y * w) / h) < 14) { r += 50; g += 50; b += 30 }
    return [Math.min(r, 255), Math.min(g, 255), Math.min(b, 255), 255]
  })
}

module.exports = { makePng, makeKIconPng, makeAppIconPng, makeSamplePng }
