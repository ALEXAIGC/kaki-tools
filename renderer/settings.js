const panelInput = document.getElementById('panel-hotkey')
const screenshotInput = document.getElementById('screenshot-hotkey')
const status = document.getElementById('status')
let recordingInput = null
const deskState = document.getElementById('desklink-state')
const hostInfo = document.getElementById('desklink-host-info')
const hostAddr = document.getElementById('host-addr')
const hostFp = document.getElementById('host-fp')

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
