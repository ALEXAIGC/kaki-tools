const { clipboard } = require('electron')
const crypto = require('crypto')

// 轮询系统剪贴板。文本直接比对;图片先用 尺寸+字节数 做廉价指纹,变化时才算 sha1。
class Watcher {
  constructor({ onText, onImage }) {
    this.onText = onText
    this.onImage = onImage
    this.suppressUntil = 0
    this.lastText = ''
    this.lastImageFp = ''
    this.timer = null
  }

  start(interval = 700) {
    this.tick()
    this.timer = setInterval(() => this.tick(), interval)
  }

  stop() { clearInterval(this.timer) }

  // 自己往剪贴板写内容后短暂停止采集,避免重复入库
  suppress(ms) { this.suppressUntil = Date.now() + ms }

  tick() {
    if (Date.now() < this.suppressUntil) return
    try {
      const formats = clipboard.availableFormats()
      const text = clipboard.readText() || ''
      if (text && text !== this.lastText) {
        this.lastText = text
        // 同时抓取富文本形态,便于「带格式复制」
        const rich = {}
        try {
          if (formats.includes('text/html')) rich.html = clipboard.readHTML()
          if (formats.includes('text/rtf')) rich.rtf = clipboard.readRTF()
        } catch {}
        this.onText(text, rich)
      }
      const hasImage = formats.some(f => f.startsWith('image/'))
      if (hasImage) {
        const img = clipboard.readImage()
        if (!img.isEmpty()) {
          const { width, height } = img.getSize()
          const png = img.toPNG()
          const fp = `${width}x${height}:${png.length}`
          if (fp !== this.lastImageFp) {
            this.lastImageFp = fp
            const hash = crypto.createHash('sha1').update(png).digest('hex')
            this.onImage(img, png, hash)
          }
        }
      }
    } catch {
      // 剪贴板偶发读取失败(被其他应用占用等),下个周期重试
    }
  }
}

module.exports = Watcher
