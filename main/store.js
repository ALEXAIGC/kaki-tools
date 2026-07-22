const fs = require('fs')
const path = require('path')
const crypto = require('crypto')

// 数据模型:
// - 普通历史条目:board 为空,受 maxTextItems/maxImageItems 滚动清理(固定的除外)
// - 标签页条目:board = 标签页名,是历史条目的独立克隆(图片文件也复制),永久保存
class Store {
  constructor(dir, { maxTextItems = 500, maxImageItems = 100 } = {}) {
    this.dir = dir
    this.imgDir = path.join(dir, 'images')
    fs.mkdirSync(this.imgDir, { recursive: true })
    this.file = path.join(dir, 'history.json')
    this.maxTextItems = maxTextItems
    this.maxImageItems = maxImageItems
    this.items = []
    this.boards = []
    this.onChange = null
    this._t = null
    this.load()
  }

  load() {
    try {
      const data = JSON.parse(fs.readFileSync(this.file, 'utf8'))
      this.items = data.items || []
      this.boards = data.boards || []
    } catch {
      this.items = []
      this.boards = []
    }
    // 图片路径按当前 images 目录重新解析,数据目录整体搬迁后依然有效
    for (const i of this.items) {
      if (i.type === 'image' && i.file) i.file = path.join(this.imgDir, path.basename(i.file))
    }
  }

  list() { return this.items }
  get(id) { return this.items.find(i => i.id === id) }

  // rich: { html, rtf } 剪贴板里的富文本形态(可选)
  addText(text, rich = {}) {
    if (!text || !text.trim()) return
    const html = rich.html && rich.html.length < 512 * 1024 ? rich.html : undefined
    const rtf = rich.rtf && rich.rtf.length < 512 * 1024 ? rich.rtf : undefined
    const head = this.items.find(i => !i.board)
    if (head && head.type === 'text' && head.text === text) return
    const ex = this.items.findIndex(i => !i.board && i.type === 'text' && i.text === text)
    if (ex >= 0) {
      const [it] = this.items.splice(ex, 1)
      it.createdAt = Date.now()
      if (html) it.html = html
      if (rtf) it.rtf = rtf
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
    const head = this.items.find(i => !i.board)
    if (head && head.type === 'image' && head.hash === hash) return
    const ex = this.items.findIndex(i => !i.board && i.type === 'image' && i.hash === hash)
    if (ex >= 0) {
      const [it] = this.items.splice(ex, 1)
      it.createdAt = Date.now()
      this.items.unshift(it)
    } else {
      const id = crypto.randomUUID()
      const file = path.join(this.imgDir, id + '.png')
      try { fs.writeFileSync(file, png) } catch (e) { console.error('保存图片失败', e); return }
      let thumb = ''
      try { thumb = img.resize({ height: 140 }).toDataURL() } catch {}
      const { width, height } = img.getSize()
      this.items.unshift({
        id, type: 'image', hash, file, thumb,
        size: { width, height },
        bytes: png.length,
        createdAt: Date.now(),
        pinned: false,
      })
    }
    this.trim()
    this.persist()
    this.emit()
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
    }
    this.items.unshift(clone)
    this.persist()
    this.emit()
  }

  trim() {
    const overflow = (type, max) => {
      const list = this.items.filter(i => i.type === type && !i.pinned && !i.board)
      return list.length > max ? list.slice(max - list.length) : []
    }
    for (const it of [...overflow('text', this.maxTextItems), ...overflow('image', this.maxImageItems)]) {
      this.removeInternal(it.id)
    }
  }

  removeInternal(id) {
    const idx = this.items.findIndex(i => i.id === id)
    if (idx < 0) return
    const [it] = this.items.splice(idx, 1)
    if (it.type === 'image' && it.file) {
      try { fs.unlinkSync(it.file) } catch {}
    }
  }

  remove(id) { this.removeInternal(id); this.persist(); this.emit() }

  togglePin(id) {
    const it = this.get(id)
    if (!it) return
    it.pinned = !it.pinned
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
    clearTimeout(this._t)
    this._t = setTimeout(() => this.flush(), 300)
  }

  flush() {
    clearTimeout(this._t)
    try {
      const tmp = this.file + '.tmp'
      fs.writeFileSync(tmp, JSON.stringify({ items: this.items, boards: this.boards }))
      fs.renameSync(tmp, this.file)
    } catch (e) {
      console.error('写入历史失败', e)
    }
  }

  emit() { if (this.onChange) this.onChange() }
}

module.exports = Store
