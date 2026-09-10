const cardsEl = document.getElementById('cards')
const searchEl = document.getElementById('search')
const emptyEl = document.getElementById('empty')
const tabsEl = document.getElementById('tabs')
const selectionIndexEl = document.getElementById('selection-index')
const selectionCopyEl = document.getElementById('selection-copy')
const actionPaste = document.getElementById('action-paste')
const actionPlain = document.getElementById('action-plain')
const actionPin = document.getElementById('action-pin')
const actionDelete = document.getElementById('action-delete')
const quitButton = document.getElementById('quit-app')
const themeButtons = Array.from(document.querySelectorAll('[data-theme-value]'))
const systemTheme = matchMedia('(prefers-color-scheme: light)')
const thumbnailCache = new Map()
const thumbnailCacheLimit = 120
let panelSuspended = false
let thumbnailGeneration = 0
const initialCardLimit = 80
const cardBatchSize = 60

let items = []
let boards = []
let query = ''
let filter = 'all'        // all | text | image | pinned
let tab = 'history'       // history | 标签页名
let sel = 0
let visibleLimit = initialCardLimit

const isMac = navigator.platform.toUpperCase().includes('MAC')
const modLabel = isMac ? '⌘' : 'Ctrl+'

window.addEventListener('error', event => {
  window.kaki.diagnostic(`error: ${event.message} @ ${event.filename}:${event.lineno}`)
})
window.addEventListener('unhandledrejection', event => {
  window.kaki.diagnostic(`unhandled rejection: ${String(event.reason)}`)
})

function applyTheme(preference, persist = true) {
  const theme = ['system', 'light', 'dark'].includes(preference) ? preference : 'system'
  const resolved = theme === 'system' ? (systemTheme.matches ? 'light' : 'dark') : theme
  document.documentElement.dataset.themePreference = theme
  document.documentElement.dataset.theme = resolved
  document.documentElement.style.colorScheme = resolved
  if (persist) localStorage.setItem('kaki-theme', theme)
  themeButtons.forEach(button => {
    const active = button.dataset.themeValue === theme
    button.classList.toggle('active', active)
    button.setAttribute('aria-pressed', String(active))
  })
}

themeButtons.forEach(button => {
  button.onclick = () => {
    applyTheme(button.dataset.themeValue)
    searchEl.focus()
  }
})
systemTheme.addEventListener('change', () => {
  if (document.documentElement.dataset.themePreference === 'system') applyTheme('system', false)
})
applyTheme(document.documentElement.dataset.themePreference || 'system', false)

function fmtTime(ts) {
  const mins = Math.floor((Date.now() - ts) / 60000)
  if (mins < 1) return '刚刚'
  if (mins < 60) return mins + ' 分钟前'
  const hours = Math.floor(mins / 60)
  if (hours < 24) return hours + ' 小时前'
  const days = Math.floor(hours / 24)
  if (days < 30) return days + ' 天前'
  const d = new Date(ts)
  return `${d.getMonth() + 1}月${d.getDate()}日`
}

function filtered() {
  const q = query.trim().toLowerCase()
  return items.filter(i => {
    if (tab === 'history' ? i.board : i.board !== tab) return false
    if (filter === 'pinned' && !i.pinned) return false
    if (filter === 'text' && i.type !== 'text') return false
    if (filter === 'image' && i.type !== 'image') return false
    if (q) {
      const searchable = [i.type === 'text' ? i.text : '', ...(i.tags || []), i.note || ''].join(' ').toLowerCase()
      return searchable.includes(q)
    }
    return true
  })
}

function renderTabs() {
  tabsEl.textContent = ''
  const mk = (label, id, isBoard) => {
    const b = document.createElement('button')
    b.className = 'tab' + (tab === id ? ' active' : '') + (id === 'history' ? ' tab-history' : '')
    if (id === 'history') {
      const icon = document.createElement('i')
      icon.dataset.lucide = 'clipboard'
      icon.setAttribute('aria-hidden', 'true')
      b.append(icon)
    }
    const text = document.createElement('span')
    text.className = 'tab-label'
    text.textContent = label
    b.append(text)
    b.onclick = () => { tab = id; sel = 0; render(); searchEl.focus() }
    if (isBoard) b.oncontextmenu = e => { e.preventDefault(); window.kaki.boardContext(id) }
    tabsEl.append(b)
  }
  mk('剪贴板', 'history', false)
  for (const b of boards) mk(b, b, true)
  const add = document.createElement('button')
  add.className = 'tab tab-add'
  add.setAttribute('aria-label', '新建标签页')
  const addIcon = document.createElement('i')
  addIcon.dataset.lucide = 'plus'
  addIcon.setAttribute('aria-hidden', 'true')
  add.append(addIcon)
  add.title = '新建标签页'
  add.onclick = () => showBoardPrompt({ mode: 'create' })
  tabsEl.append(add)
}

function updateSel() {
  Array.from(cardsEl.children).forEach((el, i) => {
    const selected = i === sel
    el.classList.toggle('selected', selected)
    el.setAttribute('aria-selected', String(selected))
    el.tabIndex = selected ? 0 : -1
  })
  updateActionbar(filtered())
}

function ensureVisible() {
  if (sel >= visibleLimit) {
    visibleLimit = Math.min(sel + cardBatchSize, filtered().length)
    render()
  }
  const el = cardsEl.children[sel]
  if (el) el.scrollIntoView({ inline: 'nearest', block: 'nearest' })
}

function activate(item, plain) {
  window.kaki.activate(item.id, { plain: !!plain })
}

function baseForCurrentTab() {
  return items.filter(i => tab === 'history' ? !i.board : i.board === tab)
}

function syncFilters() {
  document.querySelectorAll('[data-f]').forEach(el => {
    el.classList.toggle('active', el.dataset.f === filter)
  })
}

function updateCounts() {
  const base = baseForCurrentTab()
  const counts = {
    all: base.length,
    text: base.filter(i => i.type === 'text').length,
    image: base.filter(i => i.type === 'image').length,
    pinned: base.filter(i => i.pinned).length,
  }
  document.querySelectorAll('[data-count]').forEach(el => {
    el.textContent = counts[el.dataset.count] || 0
  })
}

function selectedItem(list = filtered()) {
  return list[sel] || null
}

function updateActionbar(list = filtered()) {
  const item = selectedItem(list)
  const disabled = !item
  for (const button of [actionPaste, actionPlain, actionPin, actionDelete]) button.disabled = disabled
  actionPlain.disabled = disabled || (item && item.type !== 'text')
  if (!item) {
    selectionIndexEl.textContent = '—'
    selectionCopyEl.textContent = '选择一个项目开始操作'
    actionPin.querySelector('span').textContent = '固定'
    return
  }
  selectionIndexEl.textContent = `${String(sel + 1).padStart(2, '0')} / ${String(list.length).padStart(2, '0')}`
  selectionCopyEl.textContent = item.type === 'text'
    ? item.text.replace(/\s+/g, ' ').slice(0, 160)
    : `图片 · ${item.size.width} × ${item.size.height}`
  actionPin.querySelector('span').textContent = item.pinned ? '取消固定' : '固定'
}

function render() {
  if (panelSuspended) return
  // 标签页可能被删除,回退到剪贴板
  if (tab !== 'history' && !boards.includes(tab)) tab = 'history'
  renderTabs()
  const fullList = filtered()
  const list = fullList.slice(0, visibleLimit)
  syncFilters()
  updateCounts()
  if (sel >= fullList.length) sel = Math.max(0, fullList.length - 1)
  cardsEl.textContent = ''
  emptyEl.hidden = list.length > 0
  emptyEl.textContent = tab === 'history'
    ? '还没有剪贴板记录 — 去复制点什么吧'
    : '这个标签页还是空的 — 在剪贴板卡片上右键「添加到标签页」'

  list.forEach((item, idx) => {
    const card = document.createElement('div')
    card.className = 'card' + (idx === sel ? ' selected' : '') + (item.pinned ? ' pinned' : '') + (item.type === 'image' ? ' image-card' : '')
    card.setAttribute('role', 'option')
    card.setAttribute('aria-selected', String(idx === sel))
    card.setAttribute('aria-label', item.type === 'text' ? `剪贴板条目 ${idx + 1}: ${item.text.slice(0, 120)}` : `剪贴板图片 ${idx + 1}, ${item.size.width} × ${item.size.height}`)
    card.tabIndex = idx === sel ? 0 : -1

    const head = document.createElement('div')
    head.className = 'card-head'
    const index = document.createElement('span')
    index.className = 'card-index'
    index.textContent = String(idx + 1).padStart(2, '0')
    const time = document.createElement('span')
    time.className = 'time'
    time.textContent = fmtTime(item.createdAt)
    head.append(index, time)

    const body = document.createElement('div')
    if (item.type === 'text') {
      body.className = 'card-body'
      body.textContent = item.text.slice(0, 600)
    } else {
      body.className = 'card-body img'
      const img = document.createElement('img')
      img.alt = '剪贴板图片预览'
      const cached = thumbnailCache.get(item.id)
      if (cached) {
        img.src = cached
      } else {
        const generation = thumbnailGeneration
        window.kaki.getThumbnail(item.id).then(thumb => {
          if (!thumb || panelSuspended || generation !== thumbnailGeneration || !img.isConnected) return
          thumbnailCache.set(item.id, thumb)
          while (thumbnailCache.size > thumbnailCacheLimit) {
            thumbnailCache.delete(thumbnailCache.keys().next().value)
          }
          if (img.isConnected) img.src = thumb
        }).catch(() => {})
      }
      body.append(img)
    }

    const foot = document.createElement('div')
    foot.className = 'card-foot'
    const metaParts = []
    if (item.type === 'text') {
      metaParts.push(`${item.chars} 个字符`)
      if (item.hasRich) metaParts.push('富文本')
    } else {
      metaParts.push(`${item.size.width} × ${item.size.height}`)
    }
    const meta = metaParts.join(' · ')
    if (idx < 9) {
      const key = document.createElement('span')
      key.className = 'key-badge'
      key.textContent = modLabel + (idx + 1)
      foot.append(key, document.createTextNode(' ' + meta))
    } else {
      foot.textContent = meta
    }

    let annotation = null
    if ((item.tags && item.tags.length) || item.note) {
      annotation = document.createElement('div')
      annotation.className = 'card-annotation'
      if (item.tags && item.tags.length) {
        const tags = document.createElement('div')
        tags.className = 'tag-list'
        item.tags.slice(0, 3).forEach(tag => {
          const chip = document.createElement('span')
          chip.className = 'tag-chip'
          chip.textContent = tag
          tags.append(chip)
        })
        if (item.tags.length > 3) {
          const extra = document.createElement('span')
          extra.className = 'tag-chip tag-extra'
          extra.textContent = `+${item.tags.length - 3}`
          tags.append(extra)
        }
        annotation.append(tags)
      }
      if (item.note) {
        const note = document.createElement('div')
        note.className = 'card-note'
        note.textContent = item.note.replace(/\s+/g, ' ')
        annotation.append(note)
      }
    }

    const actions = document.createElement('div')
    actions.className = 'card-actions'
    const metadataBtn = document.createElement('button')
    const metadataIcon = document.createElement('i')
    metadataIcon.dataset.lucide = 'tag'
    metadataBtn.append(metadataIcon)
    metadataBtn.title = '标签与备注'
    metadataBtn.setAttribute('aria-label', metadataBtn.title)
    metadataBtn.onclick = e => { e.stopPropagation(); showItemMetadata(item) }
    actions.append(metadataBtn)
    if (!item.board) {
      const pinBtn = document.createElement('button')
      const pinIcon = document.createElement('i')
      pinIcon.dataset.lucide = item.pinned ? 'pin-off' : 'pin'
      pinBtn.append(pinIcon)
      pinBtn.title = item.pinned ? '取消固定' : '固定'
      pinBtn.setAttribute('aria-label', pinBtn.title)
      pinBtn.onclick = e => { e.stopPropagation(); window.kaki.togglePin(item.id) }
      actions.append(pinBtn)
    }
    const delBtn = document.createElement('button')
    const delIcon = document.createElement('i')
    delIcon.dataset.lucide = 'trash-2'
    delBtn.append(delIcon)
    delBtn.title = item.board ? '从标签页移除' : '删除'
    delBtn.setAttribute('aria-label', delBtn.title)
    delBtn.className = 'card-delete'
    delBtn.onclick = e => { e.stopPropagation(); window.kaki.remove(item.id) }
    actions.append(delBtn)

    card.append(head, body, ...(annotation ? [annotation] : []), foot, actions)
    card.onclick = e => activate(item, e.shiftKey)
    card.oncontextmenu = e => { e.preventDefault(); window.kaki.itemContext(item.id, item.board) }
    card.onmouseenter = () => { sel = idx; updateSel() }
    card.onfocus = () => { sel = idx; updateSel() }
    cardsEl.append(card)
  })
  updateActionbar(fullList)
  lucide.createIcons()
}

// ---- 新建 / 重命名标签页弹层 ----
const promptEl = document.getElementById('board-prompt')
const promptInput = document.getElementById('board-prompt-input')
const promptTitle = document.getElementById('board-prompt-title')
let promptCtx = null

function showBoardPrompt(ctx) {
  promptCtx = ctx
  promptTitle.textContent = ctx.mode === 'rename' ? `重命名「${ctx.oldName}」` : '新建标签页'
  promptInput.value = ctx.mode === 'rename' ? ctx.oldName : ''
  promptEl.hidden = false
  promptInput.focus()
}

function closeBoardPrompt() {
  promptEl.hidden = true
  promptCtx = null
  searchEl.focus()
}

promptInput.addEventListener('keydown', e => {
  e.stopPropagation()
  if (e.key === 'Enter') {
    const name = promptInput.value.trim()
    if (name && promptCtx) {
      if (promptCtx.mode === 'rename') {
        window.kaki.renameBoard({ oldName: promptCtx.oldName, newName: name })
      } else {
        window.kaki.createBoard({ name, addItemId: promptCtx.itemId })
        tab = name
      }
    }
    closeBoardPrompt()
  } else if (e.key === 'Escape') {
    closeBoardPrompt()
  }
})
document.getElementById('board-prompt-cancel').onclick = closeBoardPrompt

window.kaki.onBoardPrompt(ctx => showBoardPrompt(ctx))

// ---- 单条记录的标签与备注 ----
const metadataEl = document.getElementById('item-metadata')
const metadataForm = document.getElementById('item-metadata-box')
const tagsInput = document.getElementById('item-tags')
const noteInput = document.getElementById('item-note')
let metadataItemId = null

function showItemMetadata(item) {
  metadataItemId = item.id
  tagsInput.value = (item.tags || []).join('，')
  noteInput.value = item.note || ''
  metadataEl.hidden = false
  lucide.createIcons()
  tagsInput.focus()
}
function closeItemMetadata() {
  metadataEl.hidden = true
  metadataItemId = null
  searchEl.focus()
}
metadataForm.addEventListener('submit', event => {
  event.preventDefault()
  if (!metadataItemId) return closeItemMetadata()
  const tags = tagsInput.value.split(/[,，]/).map(tag => tag.trim()).filter(Boolean)
  window.kaki.updateMetadata({ id: metadataItemId, tags, note: noteInput.value })
  closeItemMetadata()
})
metadataEl.addEventListener('keydown', event => {
  if (event.key === 'Escape') { event.preventDefault(); closeItemMetadata() }
})
metadataEl.onclick = event => { if (event.target === metadataEl) closeItemMetadata() }
document.getElementById('item-metadata-close').onclick = closeItemMetadata
document.getElementById('item-metadata-cancel').onclick = closeItemMetadata
window.kaki.onItemMetadata(showItemMetadata)

// ---- 键盘 ----
window.addEventListener('keydown', e => {
  if (!promptEl.hidden || !metadataEl.hidden) return // 弹层打开时不响应面板快捷键
  if (e.key === 'Escape') { window.kaki.hide(); return }
  const list = filtered()
  const item = selectedItem(list)
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'f') {
    e.preventDefault()
    searchEl.focus()
    searchEl.select()
    return
  }
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'q') {
    e.preventDefault()
    window.kaki.quit()
    return
  }
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'p' && item) {
    e.preventDefault()
    window.kaki.togglePin(item.id)
    return
  }
  if ((e.key === 'Backspace' || e.key === 'Delete') && document.activeElement !== searchEl && item) {
    e.preventDefault()
    window.kaki.remove(item.id)
    return
  }
  if ((e.metaKey || e.ctrlKey) && /^[1-9]$/.test(e.key)) {
    e.preventDefault()
    const item = list[Number(e.key) - 1]
    if (item) activate(item, e.shiftKey)
    return
  }
  if (e.key === 'ArrowRight') {
    e.preventDefault()
    if (sel < list.length - 1) { sel++; updateSel(); ensureVisible() }
  } else if (e.key === 'ArrowLeft') {
    e.preventDefault()
    if (sel > 0) { sel--; updateSel(); ensureVisible() }
  } else if (e.key === 'Enter') {
    e.preventDefault()
    if (list[sel]) activate(list[sel], e.shiftKey)
  }
})

searchEl.addEventListener('input', () => {
  query = searchEl.value
  sel = 0
  visibleLimit = initialCardLimit
  render()
})

document.querySelectorAll('[data-f]').forEach(control => {
  control.onclick = () => {
    filter = control.dataset.f
    sel = 0
    visibleLimit = initialCardLimit
    render()
    searchEl.focus()
  }
})

actionPaste.onclick = () => {
  const item = selectedItem()
  if (item) activate(item, false)
}
actionPlain.onclick = () => {
  const item = selectedItem()
  if (item && item.type === 'text') activate(item, true)
}
actionPin.onclick = () => {
  const item = selectedItem()
  if (item) window.kaki.togglePin(item.id)
}
actionDelete.onclick = () => {
  const item = selectedItem()
  if (item) window.kaki.remove(item.id)
}
quitButton.onclick = () => window.kaki.quit()

// 鼠标滚轮纵向滚动 → 卡片区横向滚动
cardsEl.addEventListener('wheel', e => {
  if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
    cardsEl.scrollLeft += e.deltaY
    e.preventDefault()
  }
}, { passive: false })

// 横向滚到尾部时再追加一批卡片，避免大历史记录首次打开造成长时间白屏。
cardsEl.addEventListener('scroll', () => {
  const fullList = filtered()
  const atEnd = cardsEl.scrollLeft + cardsEl.clientWidth >= cardsEl.scrollWidth - 80
  if (atEnd && visibleLimit < fullList.length) {
    visibleLimit = Math.min(visibleLimit + cardBatchSize, fullList.length)
    render()
  }
}, { passive: true })

function applyData(data) {
  if (panelSuspended) return
  const nextItems = data.items || []
  const activeImageIds = new Set(nextItems.filter(item => item.type === 'image').map(item => item.id))
  for (const id of thumbnailCache.keys()) {
    if (!activeImageIds.has(id)) thumbnailCache.delete(id)
  }
  items = nextItems
  boards = data.boards || []
  // 保留已加载的缩略图和当前卡片批次；后台新增一条历史不应让可见图片重新走 IPC。
  visibleLimit = Math.max(initialCardLimit, Math.min(visibleLimit, items.length || initialCardLimit))
  render()
}

window.kaki.onUpdate(applyData)

window.kaki.onHidden(() => {
  panelSuspended = true
  thumbnailGeneration++
  cardsEl.replaceChildren()
  thumbnailCache.clear()
  items = []
  visibleLimit = initialCardLimit
})

window.kaki.onShown(() => {
  panelSuspended = false
  query = ''
  searchEl.value = ''
  sel = 0
  closeBoardPrompt()
  searchEl.focus()
  render()
})

window.kaki.getHistory().then(applyData)

// 每 30 秒刷新一次相对时间
setInterval(() => { if (document.visibilityState === 'visible' && promptEl.hidden) render() }, 30000)
