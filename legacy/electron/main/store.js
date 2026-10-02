const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const { fitImage } = require('./image-size')
const { encodeImage, validateImageSize, MAX_IMAGE_BYTES, MAX_QUEUE_BYTES } = require('./image-encoder')
const { DEFAULT_HISTORY_LIMIT, historyLimit } = require('./history-policy')

// 数据模型:
// - 普通历史条目:board 为空,受 maxHistoryItems 滚动清理(固定的除外)
// - 标签页条目:board = 标签页名,是历史条目的独立克隆(图片文件也复制),永久保存
class Store {
  constructor(dir, { maxHistoryItems = DEFAULT_HISTORY_LIMIT } = {}) {
    this.dir = dir
    this.imgDir = path.join(dir, 'images')
    fs.mkdirSync(this.imgDir, { recursive: true })
    this.file = path.join(dir, 'history.json')
    this.backupFile = path.join(dir, 'history.backup.json')
    // 普通历史统一按时间保留最近 N 条；标签页收藏不受此限制。
    this.maxHistoryItems = historyLimit(maxHistoryItems)
    this.items = []
    this.boards = []
    this.onChange = null
    this.onImageError = null
    this._flushTimer = null
    this._writing = false
    this._revision = 0
    this._savedRevision = 0
    this._tempSequence = 0
    this._lastBackupAt = 0
    this._backupWriting = false
    this._writeFailures = 0
    this._retryAt = 0
    this._pendingImages = new Map()
    this._pendingImageBytes = 0
    this.cleanupImageTemps()
    this.load()
    const loadedCount = this.items.length
    this.trim()
    // Upgrade trimming comes first: do not write previews for discarded history.
    for (const item of this.items) {
      if (item.type === 'image' && item.file) this.offloadThumbnail(item)
    }
    if (this.items.length !== loadedCount) this.persist()
  }

  cleanupImageTemps() {
    // Only our v4 UUID staging files are disposable. Keep saved PNGs, directories,
    // symlinks and user filenames; never touch a task still owned by this Store.
    const generated = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.png\.pending$/
    const active = new Set([...this._pendingImages.values()].map(pending => pending.tmp))
    try {
      for (const entry of fs.readdirSync(this.imgDir, { withFileTypes: true })) {
        const file = path.join(this.imgDir, entry.name)
        if (!entry.isFile() || !generated.test(entry.name) || active.has(file)) continue
        try { fs.unlinkSync(file) } catch {}
      }
    } catch {}
  }

  load() {
    const read = file => {
      try {
        const data = JSON.parse(fs.readFileSync(file, 'utf8'))
        if (!data || typeof data !== 'object') return null
        return {
          items: Array.isArray(data.items) ? data.items : [],
          boards: Array.isArray(data.boards) ? data.boards : [],
        }
      } catch { return null }
    }
    const primary = read(this.file)
    const backup = primary ? null : read(this.backupFile)
    const data = primary || backup || { items: [], boards: [] }
    this.items = data.items
    this.boards = data.boards
    if (backup) console.warn('历史主文件不可用，已从本地备份恢复')
    // 第一次升级后的现有历史也立即获得一份恢复副本，不等待下一次复制操作。
    if (primary && !fs.existsSync(this.backupFile)) fs.copyFile(this.file, this.backupFile, () => {})
    // 图片路径按当前 images 目录重新解析,数据目录整体搬迁后依然有效
    for (const i of this.items) {
      if (i.type === 'image' && i.file) {
        i.file = path.join(this.imgDir, path.basename(i.file))
      }
    }
  }

  list() { return this.items }
  get(id) {
    // 立即粘贴或收藏时，确保尚未完成的图片已落盘。
    const pending = this._pendingImages.get(id)
    if (pending) this.finishImageSync(pending)
    return this.items.find(i => i.id === id)
  }

  // 写入成功后才移除旧内嵌缩略图；失败时继续使用原数据。
  offloadThumbnail(item) {
    if (!item.file || !item.thumb) return
    try {
      fs.writeFileSync(item.file + '.thumb', item.thumb, { mode: 0o600 })
      delete item.thumb
    } catch {}
  }

  async getThumbnail(id) {
    const item = this.items.find(i => i.id === id)
    if (!item || item.type !== 'image') return ''
    if (item.thumb) return item.thumb
    if (!item.file) return ''
    try { return await fs.promises.readFile(item.file + '.thumb', 'utf8') } catch { return '' }
  }

  // rich: { html, rtf } 剪贴板里的富文本形态(可选)
  addText(text, rich = {}) {
    if (!text || !text.trim()) return
    const html = rich.html && rich.html.length < 512 * 1024 ? rich.html : undefined
    const rtf = rich.rtf && rich.rtf.length < 512 * 1024 ? rich.rtf : undefined
    const head = this.items.find(i => !i.board)
    if (head && head.type === 'text' && head.text === text && head.html === html && head.rtf === rtf) return
    const ex = this.items.findIndex(i => !i.board && i.type === 'text' && i.text === text)
    if (ex >= 0) {
      const [it] = this.items.splice(ex, 1)
      it.createdAt = Date.now()
      it.html = html
      it.rtf = rtf
      this.items.unshift(it)
    } else {
      this.items.unshift({
        id: crypto.randomUUID(),
        type: 'text',
        text,
        html,
        rtf,
        createdAt: Date.now(),
        pinned: false,
      })
    }
    this.trim()
    this.persist()
    this.emit()
  }

  addImage(img, png, hash) {
    let size
    try { size = validateImageSize(img, png) } catch (error) { this.reportImageError(error); return }
    const head = this.items.find(i => !i.board)
    if (head && head.type === 'image' && head.hash === hash) return
    const ex = this.items.findIndex(i => !i.board && i.type === 'image' && i.hash === hash)
    if (ex >= 0) {
      const [it] = this.items.splice(ex, 1)
      it.createdAt = Date.now()
      this.items.unshift(it)
    } else {
      // Keep the reservation through disk I/O, not only until worker encoding ends.
      const reservation = Math.max(size.bytes * 2, png ? png.length : 0)
      if (this._pendingImageBytes + reservation > MAX_QUEUE_BYTES) {
        this.reportImageError(this.imageQueueError())
        return
      }
      const id = crypto.randomUUID()
      const file = path.join(this.imgDir, id + '.png')
      let thumb = ''
      const { width, height } = size
      try { thumb = img.resize(fitImage(width, height, 280, 140)).toDataURL() } catch {}
      this.items.unshift({
        id, type: 'image', hash, file, thumb,
        size: { width, height },
        bytes: png ? png.length : 0,
        createdAt: Date.now(),
        pinned: false,
      })
      this.saveImageAsync(this.items[0], png, img, reservation)
    }
    this.trim()
    this.persist()
    this.emit()
  }

  reportImageError(error) {
    console.error('保存剪贴板图片失败', error)
    if (this.onImageError) this.onImageError(error)
  }

  imageQueueError() {
    return Object.assign(Error('图片处理与写入队列已达到 384 MiB 预算，未加入历史'), { code: 'IMAGE_QUEUE_FULL' })
  }

  reserveEncodedImage(pending, bytes) {
    const extra = Math.max(0, bytes - pending.reservation)
    if (this._pendingImageBytes + extra > MAX_QUEUE_BYTES) return false
    this._pendingImageBytes += extra
    pending.reservation += extra
    return true
  }

  releasePendingImage(pending) {
    if (pending.done) return
    pending.done = true
    this._pendingImageBytes -= pending.reservation
    pending.reservation = 0
    this._pendingImages.delete(pending.item.id)
    pending.controller.abort()
    pending.img = null
    pending.png = null
    try { fs.unlinkSync(pending.tmp) } catch {}
  }

  saveImageAsync(item, png, img, reservation) {
    const pending = { item, png, img: png ? null : img, tmp: item.file + '.pending', reservation,
      done: false, controller: new AbortController() }
    this._pendingImageBytes += reservation
    // Callbacks keep only this small lifecycle object; clearing its fields really
    // releases the native image, including after synchronous paste/exit fallback.
    img = null
    png = null
    this._pendingImages.set(item.id, pending)
    const fail = error => {
      if (pending.done) return
      this.remove(item.id)
      fs.unlink(pending.tmp, () => {})
      this.reportImageError(error)
    }
    // Temporary writes cannot replace a synchronously finished/deleted capture.
    const write = encoded => {
      if (pending.done) return
      if (!encoded) return fail(Error('图片编码未返回内容'))
      if (encoded.length > MAX_IMAGE_BYTES) {
        fail(Object.assign(Error('编码图片超过 160 MiB，未加入历史'), { code: 'IMAGE_TOO_LARGE' }))
        return
      }
      if (!this.reserveEncodedImage(pending, encoded.length)) { fail(this.imageQueueError()); return }
      pending.png = encoded
      pending.img = null
      item.bytes = encoded.length
      fs.writeFile(pending.tmp, encoded, error => {
        if (pending.done) { fs.unlink(pending.tmp, () => {}); return }
        if (error) { fail(error); return }
        try { fs.renameSync(pending.tmp, item.file) } catch (error) { fail(error); return }
        this.releasePendingImage(pending)
        this.saveThumbnailAsync(item)
        this.persist()
      })
    }
    if (pending.png) write(pending.png)
    else encodeImage(pending.img, { signal: pending.controller.signal }).then(encoded => {
      if (!pending.done) write(encoded)
    }).catch(error => {
      if (pending.done) return
      // Synchronous encoding must not circumvent the memory admission policy.
      if (['IMAGE_TOO_LARGE', 'IMAGE_QUEUE_FULL', 'INVALID_IMAGE_SIZE'].includes(error.code)) {
        fail(error)
        return
      }
      console.error('后台图片编码失败，使用原生编码兜底', error)
      try { write(pending.img.toPNG()) } catch (error) { fail(error) }
    })
  }

  saveThumbnailAsync(item) {
    if (!item.thumb) return
    const thumb = item.thumb
    fs.writeFile(item.file + '.thumb', thumb, { mode: 0o600 }, error => {
      if (!this.items.includes(item)) { fs.unlink(item.file + '.thumb', () => {}); return }
      if (!error && item.thumb === thumb) { delete item.thumb; this.persist() }
    })
  }

  finishImageSync(pending) {
    if (pending.done) return
    let tmp
    try {
      if (!pending.png) pending.png = pending.img.toPNG()
      if (pending.png.length > MAX_IMAGE_BYTES) {
        const error = Object.assign(Error('编码图片超过 160 MiB，未加入历史'), { code: 'IMAGE_TOO_LARGE' })
        this.remove(pending.item.id)
        this.reportImageError(error)
        return
      }
      if (!this.reserveEncodedImage(pending, pending.png.length)) {
        this.remove(pending.item.id)
        this.reportImageError(this.imageQueueError())
        return
      }
      // A separate, exclusive staging file also protects an existing committed PNG
      // from partial disk errors and never races the original asynchronous writer.
      tmp = path.join(this.imgDir, crypto.randomUUID() + '.png.pending')
      fs.writeFileSync(tmp, pending.png, { flag: 'wx', mode: 0o600 })
      fs.renameSync(tmp, pending.item.file)
      tmp = null
      pending.item.bytes = pending.png.length
      this.releasePendingImage(pending)
      this.saveThumbnailAsync(pending.item)
    } catch (error) {
      console.error('保存待写入图片失败', error)
      throw error
    } finally {
      if (tmp) { try { fs.unlinkSync(tmp) } catch {} }
    }
  }

  // 复制历史条目后,把它挪到最前(标签页条目保持原位)
  touch(id) {
    const idx = this.items.findIndex(i => i.id === id)
    if (idx < 0 || this.items[idx].board) return
    const [it] = this.items.splice(idx, 1)
    it.createdAt = Date.now()
    this.items.unshift(it)
    this.persist()
    this.emit()
  }

  // ---- 标签页 ----

  createBoard(name) {
    name = String(name || '').trim().slice(0, 20)
    if (!name || this.boards.includes(name)) return null
    this.boards.push(name)
    this.persist()
    this.emit()
    return name
  }

  renameBoard(oldName, newName) {
    newName = String(newName || '').trim().slice(0, 20)
    const idx = this.boards.indexOf(oldName)
    if (idx < 0 || !newName || this.boards.includes(newName)) return
    this.boards[idx] = newName
    for (const i of this.items) if (i.board === oldName) i.board = newName
    this.persist()
    this.emit()
  }

  deleteBoard(name) {
    this.boards = this.boards.filter(b => b !== name)
    for (const it of this.items.filter(i => i.board === name)) this.removeInternal(it.id)
    this.persist()
    this.emit()
  }

  // 把条目克隆进标签页(图片文件一并复制,与历史条目生命周期解耦)
  addToBoard(id, board) {
    const src = this.get(id)
    if (!src || !this.boards.includes(board)) return
    if (this.items.some(i => i.board === board && (
      (i.type === 'text' && i.text === src.text) || (i.type === 'image' && i.hash === src.hash)
    ))) return // 该标签页里已有同样内容
    const clone = { ...src, id: crypto.randomUUID(), board, pinned: false, createdAt: Date.now() }
    if (src.type === 'image' && src.file) {
      const newFile = path.join(this.imgDir, clone.id + '.png')
      try { fs.copyFileSync(src.file, newFile); clone.file = newFile } catch { return }
      if (!clone.thumb) {
        try { fs.copyFileSync(src.file + '.thumb', newFile + '.thumb') } catch {}
      }
    }
    this.items.unshift(clone)
    this.persist()
    this.emit()
  }

  trim() {
    const history = this.items.filter(i => !i.board && !i.pinned)
    const overflow = history.length > this.maxHistoryItems
      ? history.slice(this.maxHistoryItems)
      : []
    for (const it of overflow) {
      this.removeInternal(it.id)
    }
  }

  removeInternal(id) {
    const idx = this.items.findIndex(i => i.id === id)
    if (idx < 0) return
    const [it] = this.items.splice(idx, 1)
    const pending = this._pendingImages.get(id)
    if (pending) this.releasePendingImage(pending)
    if (it.type === 'image' && it.file) {
      try { fs.unlinkSync(it.file) } catch {}
      try { fs.unlinkSync(it.file + '.thumb') } catch {}
    }
  }

  remove(id) { this.removeInternal(id); this.persist(); this.emit() }

  togglePin(id) {
    const it = this.get(id)
    if (!it) return
    it.pinned = !it.pinned
    this.trim()
    this.persist()
    this.emit()
  }

  // 标签和备注属于单条记录本身；分组中的收藏是独立副本，可分别维护说明。
  updateMetadata(id, { tags, note } = {}) {
    const it = this.get(id)
    if (!it) return
    const seen = new Set()
    const cleanTags = (Array.isArray(tags) ? tags : [])
      .map(tag => String(tag || '').trim().slice(0, 20))
      .filter(tag => {
        const key = tag.toLocaleLowerCase()
        if (!tag || seen.has(key)) return false
        seen.add(key)
        return true
      })
      .slice(0, 8)
    const cleanNote = String(note || '').trim().slice(0, 280)
    if (cleanTags.length) it.tags = cleanTags
    else delete it.tags
    if (cleanNote) it.note = cleanNote
    else delete it.note
    this.persist()
    this.emit()
  }

  // 只清空剪贴板历史(含固定),标签页里的收藏不动
  clear() {
    for (const it of this.items.filter(i => !i.board)) this.removeInternal(it.id)
    this.persist()
    this.emit()
  }

  persist() {
    this._revision++
    clearTimeout(this._flushTimer)
    this._flushTimer = setTimeout(() => this.flush(), Math.max(300, this._retryAt - Date.now()))
  }

  flush() {
    clearTimeout(this._flushTimer)
    this._flushTimer = null
    if (this._pendingImages.size || this._writing || this._savedRevision === this._revision) return

    const revision = this._revision
    const tmp = `${this.file}.${process.pid}.${++this._tempSequence}.tmp`
    let payload
    try {
      // 先在内存中冻结当前快照，后续 I/O 不再阻塞剪贴板监听与自动粘贴。
      payload = JSON.stringify({ items: this.items, boards: this.boards })
    } catch (e) {
      console.error('序列化历史失败', e)
      return
    }

    this._writing = true
    fs.writeFile(tmp, payload, error => {
      const stale = revision !== this._revision
      const finish = (renameError, wrotePrimary = false) => {
        this._writing = false
        if (renameError) {
          console.error('写入历史失败', renameError)
          fs.unlink(tmp, () => {})
          this._writeFailures++
          this._retryAt = Date.now() + Math.min(30000, 1000 * 2 ** Math.min(this._writeFailures - 1, 5))
          // 最多自动重试五次；之后保留未保存状态，新修改或退出时再尝试。
          if (this._writeFailures <= 5) {
            this._flushTimer = setTimeout(() => this.flush(), this._retryAt - Date.now())
          }
          return
        }
        else {
          if (wrotePrimary) {
            this._savedRevision = revision
            this._writeFailures = 0
            this._retryAt = 0
            this.writeBackup(payload)
          }
        }
        if (this._savedRevision !== this._revision) this.flush()
      }
      if (error) return finish(error)
      // 不能让较旧的异步写覆盖刚刚发生的新修改或退出时的同步刷盘。
      if (stale) return fs.unlink(tmp, () => finish())
      // The revision check and short atomic commit must share one event-loop turn;
      // an async rename could otherwise overwrite a newer flushSync on exit.
      try { fs.renameSync(tmp, this.file); finish(null, true) } catch (error) { finish(error) }
    })
  }

  // 备份最多每 30 秒更新一次：主历史仍是每次原子写入，备份只承担损坏恢复，避免翻倍 I/O。
  writeBackup(payload) {
    if (this._backupWriting || Date.now() - this._lastBackupAt < 30000) return
    this._lastBackupAt = Date.now()
    this._backupWriting = true
    const tmp = `${this.backupFile}.${process.pid}.${++this._tempSequence}.tmp`
    fs.writeFile(tmp, payload, error => {
      if (error) { this._backupWriting = false; return }
      fs.rename(tmp, this.backupFile, renameError => {
        this._backupWriting = false
        if (renameError) fs.unlink(tmp, () => {})
      })
    })
  }

  // 只在应用退出时调用，保证异步写尚未完成也不会丢失最后一次修改。
  flushSync() {
    for (const pending of [...this._pendingImages.values()]) {
      try { this.finishImageSync(pending) } catch (error) {
        // One failed capture must not prevent unrelated text/history from saving.
        // Atomic staging leaves any previously committed image intact.
        if (fs.existsSync(pending.item.file)) {
          this.releasePendingImage(pending)
          try { pending.item.bytes = fs.statSync(pending.item.file).size } catch {}
          this.persist()
        } else this.remove(pending.item.id)
        this.reportImageError(error)
      }
    }
    clearTimeout(this._flushTimer)
    this._flushTimer = null
    if (this._savedRevision === this._revision) return
    try {
      const tmp = `${this.file}.${process.pid}.exit.tmp`
      fs.writeFileSync(tmp, JSON.stringify({ items: this.items, boards: this.boards }))
      fs.renameSync(tmp, this.file)
      this._savedRevision = this._revision
    } catch (e) {
      console.error('退出时写入历史失败', e)
    }
  }

  emit() { if (this.onChange) this.onChange() }
}

module.exports = Store
