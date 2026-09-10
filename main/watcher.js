const { clipboard } = require('electron')
const crypto = require('crypto')
const { fitImage } = require('./image-size')

// 轮询系统剪贴板。文本直接比对；图片仅对缩小后的位图做指纹，确认变化后才 PNG 编码并存盘。
class Watcher {
  constructor({ onText, onImage }) {
    this.onText = onText
    this.onImage = onImage
    this.suppressUntil = 0
    this.lastText = ''
    this.lastImageFp = ''
    this.timer = null
    this.imageTimer = null
    this.pollInterval = 700
    this.nativeChangeMonitor = false
  }

  start(interval = 700) {
    this.stop()
    this.pollInterval = Math.max(80, Number(interval) || 700)
    this.nativeChangeMonitor = false
    this.startPolling()
  }

  startPolling() {
    this.stopTimers()
    // 兼容后备：文本路径轻量且高频；图片检测独立运行。
    this.tickText()
    this.tickImage()
    this.timer = setInterval(() => this.tickText(), this.pollInterval)
    this.imageTimer = setInterval(() => this.tickImage(), 500)
  }

  stopTimers() {
    clearInterval(this.timer)
    clearInterval(this.imageTimer)
    this.timer = null
    this.imageTimer = null
  }

  stop() {
    this.nativeChangeMonitor = false
    this.stopTimers()
  }

  // macOS 原生桥只在 changeCount 变化时通知我们。这样不再重复读取文本和
  // 图片剪贴板；桥不可用时会立即恢复原有轮询路径。
  setNativeChangeMonitor(enabled) {
    const next = !!enabled
    if (next === this.nativeChangeMonitor) return
    this.nativeChangeMonitor = next
    if (next) {
      this.stopTimers()
      this.tickFromNativeChange()
    } else {
      this.startPolling()
    }
  }

  // 自己往剪贴板写内容后短暂停止采集,避免重复入库
  suppress(ms) { this.suppressUntil = Date.now() + ms }

  tickText(formats) {
    if (Date.now() < this.suppressUntil) return
    try {
      const available = formats || clipboard.availableFormats()
      const text = clipboard.readText() || ''
      if (text && text !== this.lastText) {
        this.lastText = text
        // 同时抓取富文本形态,便于「带格式复制」
        const rich = {}
        try {
          if (available.includes('text/html')) rich.html = clipboard.readHTML()
          if (available.includes('text/rtf')) rich.rtf = clipboard.readRTF()
        } catch {}
        this.onText(text, rich)
      }
    } catch {
      // 剪贴板偶发读取失败(被其他应用占用等),下个周期重试
    }
  }

  tickImage(formats) {
    if (Date.now() < this.suppressUntil) return
    try {
      const available = formats || clipboard.availableFormats()
      if (!available.some(f => f.startsWith('image/'))) {
        // 图片 -> 文本 -> 同一张图片是一次新的复制操作，不能被旧指纹吞掉。
        this.lastImageFp = ''
        return
      }
      const img = clipboard.readImage()
      if (img.isEmpty()) return
      const { width, height } = img.getSize()
      // 指纹最多 64 × 64，长截图也不会生成无界位图。
      const sample = img.resize(fitImage(width, height, 64, 64)).toBitmap()
      const hash = crypto.createHash('sha1').update(`${width}x${height}:`).update(sample).digest('hex')
      if (hash === this.lastImageFp) return
      this.lastImageFp = hash
      // 原图编码交给存储层的工作线程，主线程只生成有界指纹。
      this.onImage(img, null, hash)
    } catch {
      // 剪贴板偶发读取失败(被其他应用占用等),下个周期重试
    }
  }

  tickFromNativeChange() {
    if (Date.now() < this.suppressUntil) return
    try {
      const formats = clipboard.availableFormats()
      this.tickText(formats)
      this.tickImage(formats)
    } catch {
      // 下一个 changeCount 通知会重试；桥异常时主进程会恢复轮询。
    }
  }

  // 保留旧调用形式，便于外部诊断或后续测试使用。
  tick(checkImage) { return checkImage ? this.tickImage() : this.tickText() }
}

module.exports = Watcher
