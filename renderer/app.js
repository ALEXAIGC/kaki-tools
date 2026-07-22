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

let items = []
let boards = []
let query = ''
let filter = 'all'        // all | text | image | pinned
let tab = 'history'       // history | 标签页名
let sel = 0

const isMac = navigator.platform.toUpperCase().includes('MAC')
const modLabel = isMac ? '⌘' : 'Ctrl+'

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
      if (i.type !== 'text') return false
      return i.text.toLowerCase().includes(q)
    }
    return true
  })
}

function renderTabs() {
  tabsEl.textContent = ''
  const mk = (label, id, isBoard) => {
    const b = document.createElement('button')
    b.className = 'tab' + (tab === id ? ' active' : '')
    b.textContent = label
    b.onclick = () => { tab = id; sel = 0; render(); searchEl.focus() }
    if (isBoard) b.oncontextmenu = e => { e.preventDefault(); window.kaki.boardContext(id) }
    tabsEl.append(b)
  }
  mk('剪贴板', 'history', false)
  for (const b of boards) mk(b, b, true)
  const add = document.createElement('button')
  add.className = 'tab tab-add'
  add.textContent = '＋'
  add.title = '新建标签页'
  add.onclick = () => showBoardPrompt({ mode: 'create' })
  tabsEl.append(add)
}

function updateSel() {
  Array.from(cardsEl.children).forEach((el, i) => el.classList.toggle('selected', i === sel))
  updateActionbar(filtered())
}

function ensureVisible() {
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
  // 标签页可能被删除,回退到剪贴板
  if (tab !== 'history' && !boards.includes(tab)) tab = 'history'
  renderTabs()
  const list = filtered()
  syncFilters()
  updateCounts()
  if (sel >= list.length) sel = Math.max(0, list.length - 1)
  cardsEl.textContent = ''
  emptyEl.hidden = list.length > 0
  emptyEl.textContent = tab === 'history'
    ? '还没有剪贴板记录 — 去复制点什么吧'
    : '这个标签页还是空的 — 在剪贴板卡片上右键「添加到标签页」'

  list.forEach((item, idx) => {
    const card = document.createElement('div')
    card.className = 'card' + (idx === sel ? ' selected' : '') + (item.pinned ? ' pinned' : '') + (item.type === 'image' ? ' image-card' : '')

    const head = document.createElement('div')
    head.className = 'card-head'
    const index = document.createElement('span')
    index.className = 'card-index'
    index.textContent = String(idx + 1).padStart(2, '0')
    const type = document.createElement('span')
    type.className = 'type'
    type.textContent = (item.pinned ? '固定 · ' : '') + (item.type === 'text' ? '文本' : '图片')
    const time = document.createElement('span')
    time.className = 'time'
    time.textContent = fmtTime(item.createdAt)
    head.append(index, type, time)

    const body = document.createElement('div')
    if (item.type === 'text') {
      body.className = 'card-body'
      body.textContent = item.text.slice(0, 600)
    } else {
      body.className = 'card-body img'
      const img = document.createElement('img')
      img.src = item.thumb
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

    const actions = document.createElement('div')
    actions.className = 'card-actions'
    if (!item.board) {
      const pinBtn = document.createElement('button')
      const pinIcon = document.createElement('i')
      pinIcon.className = 'ph ' + (item.pinned ? 'ph-push-pin-slash' : 'ph-push-pin')
      pinBtn.append(pinIcon)
      pinBtn.title = item.pinned ? '取消固定' : '固定'
      pinBtn.onclick = e => { e.stopPropagation(); window.kaki.togglePin(item.id) }
      actions.append(pinBtn)
    }
    const delBtn = document.createElement('button')
    const delIcon = document.createElement('i')
    delIcon.className = 'ph ph-trash'
    delBtn.append(delIcon)
    delBtn.title = item.board ? '从标签页移除' : '删除'
    delBtn.onclick = e => { e.stopPropagation(); window.kaki.remove(item.id) }
    actions.append(delBtn)

    card.append(head, body, foot, actions)
    card.onclick = e => activate(item, e.shiftKey)
    card.oncontextmenu = e => { e.preventDefault(); window.kaki.itemContext(item.id, item.board) }
    card.onmouseenter = () => { sel = idx; updateSel() }
    cardsEl.append(card)
  })
  updateActionbar(list)
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

// ---- 键盘 ----
window.addEventListener('keydown', e => {
  if (!promptEl.hidden) return // 弹层打开时不响应面板快捷键
  if (e.key === 'Escape') { window.kaki.hide(); return }
  const list = filtered()
  const item = selectedItem(list)
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'f') {
    e.preventDefault()
    searchEl.focus()
    searchEl.select()
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
  render()
})

document.querySelectorAll('[data-f]').forEach(control => {
  control.onclick = () => {
    filter = control.dataset.f
    sel = 0
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

// 鼠标滚轮纵向滚动 → 卡片区横向滚动
cardsEl.addEventListener('wheel', e => {
  if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
    cardsEl.scrollLeft += e.deltaY
    e.preventDefault()
  }
}, { passive: false })

function applyData(data) {
  items = data.items || []
  boards = data.boards || []
  render()
}

window.kaki.onUpdate(applyData)

window.kaki.onShown(() => {
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
