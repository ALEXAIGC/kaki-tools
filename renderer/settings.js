const panelInput = document.getElementById('panel-hotkey')
const screenshotInput = document.getElementById('screenshot-hotkey')
const status = document.getElementById('status')
let recordingInput = null
const deskState = document.getElementById('desklink-state')
const hostInfo = document.getElementById('desklink-host-info')
const hostAddr = document.getElementById('host-addr')
const hostFp = document.getElementById('host-fp')
const gridBox = document.getElementById('desklink-grid-box')
const gridEl = document.getElementById('desklink-grid')
const GRID_COLS = 5
const GRID_ROWS = 3

// 标签页切换
const tabs = Array.from(document.querySelectorAll('.tab'))
const panels = Array.from(document.querySelectorAll('.tab-panel'))
for (const tab of tabs) {
  tab.onclick = () => {
    for (const t of tabs) t.classList.toggle('active', t === tab)
    for (const p of panels) p.classList.toggle('active', p.id === `panel-${tab.dataset.tab}`)
  }
}

// 一键复制按钮
for (const btn of document.querySelectorAll('.mini[data-copy]')) {
  btn.onclick = async () => {
    const el = document.getElementById(btn.dataset.copy)
    if (!el || !el.textContent || el.textContent === '—') return
    await window.kaki.copyText(el.textContent)
    const original = btn.textContent
    btn.textContent = '已复制'
    setStatus('已复制到剪贴板。', 'success')
    setTimeout(() => { btn.textContent = original }, 1200)
  }
}

function displayName(name) {
  const short = String(name || '').replace(/\.local$/i, '')
  return short.length > 14 ? short.slice(0, 13) + '…' : short
}

function renderGrid(layout, deviceName) {
  const entries = Object.entries(layout || {})
  gridBox.hidden = entries.length === 0
  gridEl.innerHTML = ''
  gridEl.style.gridTemplateColumns = `repeat(${GRID_COLS}, 1fr)`

  const cellName = {}
  for (const [name, pos] of entries) {
    if (pos && pos.col >= 0 && pos.col < GRID_COLS && pos.row >= 0 && pos.row < GRID_ROWS) {
      cellName[pos.row * GRID_COLS + pos.col] = name
    }
  }

  for (let row = 0; row < GRID_ROWS; row++) {
    for (let col = 0; col < GRID_COLS; col++) {
      const cell = document.createElement('div')
      cell.className = 'grid-cell'
      cell.dataset.col = col
      cell.dataset.row = row
      const name = cellName[row * GRID_COLS + col]
      if (name) {
        cell.classList.add('occupied')
        if (name === deviceName) cell.classList.add('host')
        cell.textContent = name === deviceName ? '本机' : displayName(name)
        cell.title = name
        cell.draggable = true
        cell.addEventListener('dragstart', e => {
          e.dataTransfer.setData('text/plain', name)
          e.dataTransfer.effectAllowed = 'move'
        })
      }
      cell.addEventListener('dragover', e => {
        e.preventDefault()
        e.dataTransfer.dropEffect = 'move'
        cell.classList.add('drag-over')
      })
      cell.addEventListener('dragleave', () => cell.classList.remove('drag-over'))
      cell.addEventListener('drop', async e => {
        e.preventDefault()
        cell.classList.remove('drag-over')
        const name = e.dataTransfer.getData('text/plain')
        if (!name) return
        const result = await window.kaki.desklinkSetLayout(name, col, row)
        if (result.ok) renderDesklink(result.state)
        else setStatus(result.message || '无法移动到该位置', 'error')
      })
      gridEl.appendChild(cell)
    }
  }
}

function renderDesklink(value) {
  if (!value) return
  deskState.textContent = value.peer ? `已连接：${value.peer.name}` : value.role === 'host' ? '主机运行中' : value.role === 'client' ? '正在连接' : '未连接'
  const show = value.role === 'host'
  hostInfo.hidden = !show
  if (show) {
    const preferred = value.addresses?.find(a => a.preferred) || value.addresses?.[0]
    hostAddr.textContent = preferred ? preferred.address : '未找到局域网地址'
    hostFp.textContent = value.fingerprint || '—'
  }
  renderGrid(value.layout, value.deviceName)
  if (value.error) setStatus(`跨屏协同：${value.error}`, 'error')
}

function displayAccelerator(value) {
  return value.replace('CommandOrControl', navigator.platform.includes('Mac') ? '⌘' : 'Ctrl')
    .replace('Command', '⌘').replace('Control', 'Ctrl').replace('Option', '⌥').replace('Alt', 'Alt').replace(/\+/g, ' + ')
}
function setStatus(message, kind = '') { status.textContent = message; status.className = kind }
function startRecording(input) {
  recordingInput = input
  for (const control of [panelInput, screenshotInput]) control.classList.toggle('recording', control === input)
  input.value = '请按快捷键…'
  input.focus()
  window.kaki.recordShortcut(input.id)
  setStatus('')
}
for (const input of [panelInput, screenshotInput]) {
  input.onclick = () => startRecording(input)
}
window.kaki.onShortcutRecorded(result => {
  const input = document.getElementById(result.target)
  if (!input) return
  input.classList.remove('recording')
  recordingInput = null
  if (result.cancelled) { input.value = displayAccelerator(input.dataset.value); return setStatus('已取消录入。') }
  input.dataset.value = result.accelerator
  input.value = displayAccelerator(result.accelerator)
  setStatus('')
})
document.getElementById('save').onclick = async () => {
  const result = await window.kaki.saveShortcuts({ panelHotkey: panelInput.dataset.value, screenshotHotkey: screenshotInput.dataset.value })
  setStatus(result.ok ? '已保存，新快捷键立即生效。' : result.message, result.ok ? 'success' : 'error')
}
document.getElementById('clear-history').onclick = () => {
  if (confirm('确认清空普通历史和固定项吗？收藏标签页会保留。')) { window.kaki.clearHistory(); setStatus('普通历史已清空。', 'success') }
}
document.getElementById('desklink-host').onclick = async () => {
  const result = await window.kaki.desklinkHost({})
  renderDesklink(result.state)
  if (result.state?.error) return
  setStatus('主机已开启，把地址和指纹发给另一台 Mac。', 'success')
}
document.getElementById('desklink-connect').onclick = async () => {
  const result = await window.kaki.desklinkConnect({
    host: document.getElementById('desklink-hostname').value.trim(),
    fingerprint: document.getElementById('desklink-fingerprint').value.trim(),
  })
  renderDesklink(result.state)
  if (result.state?.error) return
  setStatus('正在连接主机…')
}
document.getElementById('desklink-stop').onclick = async () => {
  const result = await window.kaki.desklinkStop()
  renderDesklink(result.state)
  setStatus('跨屏协同已停止。')
}
window.kaki.onDesklinkStatus(renderDesklink)
window.kaki.onDesklinkError(message => setStatus(`跨屏协同：${message}`, 'error'))
window.kaki.getSettings().then(data => {
  panelInput.dataset.value = data.panelHotkey; panelInput.value = displayAccelerator(data.panelHotkey)
  screenshotInput.dataset.value = data.screenshotHotkey; screenshotInput.value = displayAccelerator(data.screenshotHotkey)
  document.getElementById('history-limit').textContent = `普通历史保留最近 ${data.maxHistoryItems} 条`
  renderDesklink(data.desklink)
})
