const { clipboard } = require('electron')
const crypto = require('crypto')
const { fitImage } = require('./image-size')
const SOURCE_FORMAT = 'com.kakitools.source'

class Watcher {
  constructor({ onText, onImage }) {
    this.onText = onText
    this.onImage = onImage
    this.sourceMarker = crypto.randomUUID()
    this.ownFallbackSignature = null
    this.lastText = ''
    this.lastTextFormats = ''
    this.lastImageFp = ''
    this.timer = null
    this.imageTimer = null
    this.retryTimer = null
    this.pollInterval = 700
    this.nativeChangeMonitor = false
  }

  start(interval = 700) {
    this.stop()
    this.pollInterval = Math.max(80, Number(interval) || 700)
    this.startPolling()
  }

  startPolling() {
    this.stopTimers()
    this.tickText()
    this.tickImage()
    this.timer = setInterval(() => this.tickText(), this.pollInterval)
    this.imageTimer = setInterval(() => this.tickImage(), 500)
  }

  stopTimers() {
    clearInterval(this.timer)
    clearInterval(this.imageTimer)
    clearTimeout(this.retryTimer)
    this.timer = this.imageTimer = this.retryTimer = null
  }

  stop() {
    this.nativeChangeMonitor = false
    this.stopTimers()
  }

  setNativeChangeMonitor(enabled) {
    const next = !!enabled
    if (next === this.nativeChangeMonitor) return
    this.nativeChangeMonitor = next
    if (next) {
      this.stopTimers()
      this.tickFromNativeChange()
    } else this.startPolling()
  }

  imageFingerprint(img) {
    const { width, height } = img.getSize()
    const sample = img.resize(fitImage(width, height, 64, 64)).toBitmap()
    return crypto.createHash('sha1').update(`${width}x${height}:`).update(sample).digest('hex')
  }

  clipboardSignature(formats) {
    const state = [clipboard.readText() || '']
    for (const [format, read] of [['text/html', 'readHTML'], ['text/rtf', 'readRTF']]) {
      state.push(formats.includes(format) ? clipboard[read]() : '')
    }
    if (formats.some(f => f.startsWith('image/'))) {
      const img = clipboard.readImage()
      state.push(img.isEmpty() ? '' : this.imageFingerprint(img))
    }
    return crypto.createHash('sha256').update(JSON.stringify(state)).digest('hex')
  }

  // Compatibility writers cannot append a custom type atomically in Electron 38.
  // Match the content they just wrote instead of dropping all copies for a time window.
  recordOwnWrite() {
    try { this.ownFallbackSignature = this.clipboardSignature(clipboard.availableFormats()) }
    catch { this.ownFallbackSignature = null }
  }

  isOwnClipboard(formats) {
    let own = false
    if (formats.includes(SOURCE_FORMAT) && clipboard.readBuffer) {
      own = clipboard.readBuffer(SOURCE_FORMAT).toString('utf8') === this.sourceMarker
    }
    if (!own && this.ownFallbackSignature) {
      own = this.clipboardSignature(formats) === this.ownFallbackSignature
      if (!own) this.ownFallbackSignature = null
    }
    if (own) {
      // External copies of the same text/image must be eligible after ownership changes.
      this.lastText = this.lastTextFormats = this.lastImageFp = ''
    }
    return own
  }

  tickText(formats, changed = false, ownershipChecked = false) {
    try {
      const available = formats || clipboard.availableFormats()
      if (!ownershipChecked && this.isOwnClipboard(available)) return true
      const text = clipboard.readText() || ''
      const textFormats = ['text/html', 'text/rtf'].filter(f => available.includes(f)).join('|')
      if (text && (changed || text !== this.lastText || textFormats !== this.lastTextFormats)) {
        const rich = {}
        if (available.includes('text/html')) rich.html = clipboard.readHTML()
        if (available.includes('text/rtf')) rich.rtf = clipboard.readRTF()
        this.onText(text, rich)
      }
      this.lastText = text
      this.lastTextFormats = textFormats
      return true
    } catch { return false }
  }

  tickImage(formats, ownershipChecked = false, changed = false) {
    try {
      const available = formats || clipboard.availableFormats()
      if (!ownershipChecked && this.isOwnClipboard(available)) return true
      if (!available.some(f => f.startsWith('image/'))) {
        this.lastImageFp = ''
        return true
      }
      const img = clipboard.readImage()
      if (img.isEmpty()) return true
      const hash = this.imageFingerprint(img)
      if (!changed && hash === this.lastImageFp) return true
      this.onImage(img, null, hash)
      this.lastImageFp = hash
      return true
    } catch { return false }
  }

  tickFromNativeChange(attempt = 0) {
    clearTimeout(this.retryTimer)
    this.retryTimer = null
    let read = false
    try {
      const formats = clipboard.availableFormats()
      if (this.isOwnClipboard(formats)) return
      const textRead = this.tickText(formats, true, true)
      const imageRead = this.tickImage(formats, true, true)
      read = textRead && imageRead
    } catch {}
    // A transient read failure may be the last change notification. Retry briefly,
    // rather than waiting forever for another copy; stopping also cancels this timer.
    if (!read && attempt < 3) {
      this.retryTimer = setTimeout(() => this.tickFromNativeChange(attempt + 1), 50)
      this.retryTimer.unref?.()
    }
  }

  tick(checkImage) { return checkImage ? this.tickImage() : this.tickText() }
}

Watcher.SOURCE_FORMAT = SOURCE_FORMAT
module.exports = Watcher
