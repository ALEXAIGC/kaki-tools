const { app, BrowserWindow, globalShortcut, Tray, Menu, ipcMain, screen, clipboard, nativeImage, systemPreferences, shell } = require('electron')
const path = require('path')
const fs = require('fs')
const os = require('os')
const { exec, execFile, spawn } = require('child_process')
const Store = require('./store')
const Watcher = require('./watcher')
const { DeskflowCore, DEFAULT_PORT } = require('./deskflow')
const icons = require('./genIcon')
const winman = require('./winman')
const logger = require('./log')

const TEST_MODE = process.env.KAKI_TEST === '1'
const isMac = process.platform === 'darwin'
const PANEL_HEIGHT = 340
const PANEL_FILE = path.join(__dirname, '../renderer/index.html')
const AUTO_PASTE_DELAY_MS = 20
const NATIVE_PASTE_RESPONSE_TIMEOUT_MS = 140
const NATIVE_PASTE_RESTART_DELAYS_MS = [250, 1000, 5000, 15000]

if (TEST_MODE) {
  app.setPath('userData', process.env.KAKI_TEST_DIR || path.join(os.tmpdir(), 'kaki-test'))
}

// 项目早期叫 ClipDeck,改名后 userData 目录变了,把旧数据搬过来
function migrateOldData(userDir) {
  try {
    if (fs.existsSync(path.join(userDir, 'history.json'))) return
    const base = path.dirname(userDir)
    for (const oldName of ['ClipDeck', 'clipdeck']) {
      const oldDir = path.join(base, oldName)
      if (!fs.existsSync(path.join(oldDir, 'history.json'))) continue
      fs.mkdirSync(userDir, { recursive: true })
      fs.copyFileSync(path.join(oldDir, 'history.json'), path.join(userDir, 'history.json'))
      const oldImg = path.join(oldDir, 'images')
      if (fs.existsSync(oldImg)) fs.cpSync(oldImg, path.join(userDir, 'images'), { recursive: true })
      const oldSettings = path.join(oldDir, 'settings.json')
      if (fs.existsSync(oldSettings) && !fs.existsSync(path.join(userDir, 'settings.json'))) {
        fs.copyFileSync(oldSettings, path.join(userDir, 'settings.json'))
      }
      console.log('[kaki] 已从旧目录迁移数据:', oldDir)
      return
    }
  } catch (e) {
    console.warn('[kaki] 旧数据迁移失败:', e.message)
  }
}

let panel = null
let settingsWindow = null
let aboutWindow = null
let tray = null
let store = null
let watcher = null
let settings = null
let activeHotkey = null
let activeScreenshotHotkey = null
let recordingShortcutTarget = null
let exiting = false
let historySnapshot = { boards: [], items: [] }
let screenshotInProgress = false
let panelRecoveryTimer = null
let panelRecoveryAttempts = 0
let pendingPasteTimer = null
let pasteGeneration = 0
let nativePasteBridge = null
let nativePasteBridgeReady = false
let nativePasteBuffer = ''
let nativePasteRequestId = 0
let nativePasteRestartTimer = null
let nativePasteRestartAttempts = 0
let nativeClipboardMonitorReady = false
let deskflowCore = null
const nativePasteRequests = new Map()

function loadSettings() {
  const file = path.join(app.getPath('userData'), 'settings.json')
  const defaults = {
    // 注册失败(比如快捷键已被 Paste 等软件占用)时,依次尝试后备快捷键
    hotkey: 'CommandOrControl+Shift+V',
    fallbackHotkeys: [isMac ? 'Command+Option+V' : 'Control+Alt+V', 'CommandOrControl+Shift+B'],
    // 普通历史总数；标签页收藏不会自动清理。
    maxHistoryItems: 500,
    hideOnBlur: true,
    showOnLaunch: true,
    // 采集剪贴板的目标延迟：120ms 在体感上接近即时，同时不至于过度占用主进程。
    pollIntervalMs: 120,
    // 选中条目后自动在原应用里执行粘贴(macOS 首次需要授予「辅助功能」权限)
    autoPaste: true,
    screenshotHotkey: 'CommandOrControl+Shift+2',
    // 窗口排列模块(Magnet 风格),快捷键可逐个覆盖或设为 null 停用
    windowManager: { enabled: true, shortcuts: winman.DEFAULT_SHORTCUTS },
  }
  try {
    const loaded = JSON.parse(fs.readFileSync(file, 'utf8'))
    settings = { ...defaults, ...loaded }
    // 兼容旧版本按文字/图片分开保存的配置。
    if (!Number.isFinite(settings.maxHistoryItems) || settings.maxHistoryItems < 1) {
      settings.maxHistoryItems = defaults.maxHistoryItems
    }
    settings.windowManager = {
      ...defaults.windowManager,
      ...(loaded.windowManager || {}),
      shortcuts: { ...defaults.windowManager.shortcuts, ...((loaded.windowManager || {}).shortcuts || {}) },
    }
  } catch {
    settings = defaults
    try { fs.writeFileSync(file, JSON.stringify(defaults, null, 2)) } catch {}
  }
}

function saveSettings() {
  const file = path.join(app.getPath('userData'), 'settings.json')
  const tmp = `${file}.${process.pid}.tmp`
  try {
    fs.writeFileSync(tmp, JSON.stringify(settings, null, 2))
    fs.renameSync(tmp, file)
    return true
  } catch (error) {
    try { fs.unlinkSync(tmp) } catch {}
    logger.log('设置保存失败:', error.message)
    return false
  }
}

// 渲染进程只消费这份内存快照，面板显示和 IPC 推送不会再重复遍历持久化历史。
// 图片缩略图通过按需 IPC 获取，避免首次打开时传输大量 base64 数据。
function refreshHistorySnapshot() {
  if (!store) return historySnapshot
  historySnapshot = {
    boards: store.boards,
    items: store.list().map(i => ({
      id: i.id,
      type: i.type,
      pinned: !!i.pinned,
      board: i.board,
      hasRich: !!(i.html || i.rtf),
      createdAt: i.createdAt,
      tags: Array.isArray(i.tags) ? i.tags : [],
      note: typeof i.note === 'string' ? i.note.slice(0, 280) : '',
      // 面板只展示最多 600 个字符；限制 IPC 预览大小，避免大量长文本拖慢首次渲染。
      text: i.type === 'text' ? String(i.text).slice(0, 800) : undefined,
      chars: i.type === 'text' ? i.text.length : undefined,
      size: i.size,
    })),
  }
  return historySnapshot
}

function broadcast({ force = false } = {}) {
  // 面板隐藏时只维护主进程快照；打开时会主动同步最新数据，避免后台重复建卡片。
  if (panel && !panel.isDestroyed() && (force || panel.isVisible())) {
    panel.webContents.send('history:updated', historySnapshot)
  }
}

function createPanel() {
  panel = new BrowserWindow({
    show: false,
    frame: false,
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    // 剪贴板属于随叫随到的工作台：保持在普通应用之上，但不使用
    // pop-up-menu 级别。区域截图前会主动隐藏该面板，把最顶层交给
    // macOS/微信的截图选框与遮罩。
    alwaysOnTop: true,
    hasShadow: true,
    transparent: isMac,
    backgroundColor: isMac ? '#00000000' : '#1c1c1e',
    vibrancy: isMac ? 'hud' : undefined,
    visualEffectState: 'active',
    backgroundMaterial: process.platform === 'win32' ? 'acrylic' : undefined,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
    },
  })
  // floating 能保证面板在正常应用前方，同时低于系统级截图/权限浮层。
  panel.setAlwaysOnTop(true, 'floating')
  panel.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true })
  panel.on('blur', () => {
    if (settings.hideOnBlur && !TEST_MODE) hidePanel()
  })
  panel.webContents.on('did-finish-load', () => {
    logger.log('面板渲染器就绪')
    broadcast()
  })
  panel.webContents.on('render-process-gone', (_event, details) => {
    logger.log('面板渲染器异常退出:', details)
    recoverPanel('渲染器异常退出', panel.isVisible())
  })
  // 正式启动时等页面真正加载完成再显示，避免菜单栏应用在后台启动后
  // 定时器被系统激活流程吞掉，只留下进程却看不到面板。
  if (!TEST_MODE && settings.showOnLaunch !== false) {
    panel.webContents.once('did-finish-load', () => {
      if (panel && !panel.isVisible()) showPanel()
    })
  }
  panel.webContents.on('did-fail-load', (_event, code, description) => {
    logger.log('面板加载失败:', code, description)
    if (code !== -3) recoverPanel(`加载失败 ${code}`, panel.isVisible())
  })
  panel.loadFile(PANEL_FILE)
}

function recoverPanel(reason, shouldShow) {
  if (!panel || panel.isDestroyed() || panelRecoveryTimer) return
  if (panelRecoveryAttempts >= 3) {
    logger.log('面板自动恢复已停止，请从菜单栏重新打开:', reason)
    return
  }
  const delay = 250 * (panelRecoveryAttempts + 1)
  panelRecoveryAttempts++
  logger.log(`面板自动恢复(${panelRecoveryAttempts}/3):`, reason)
  panelRecoveryTimer = setTimeout(() => {
    panelRecoveryTimer = null
    if (!panel || panel.isDestroyed()) return
    panel.webContents.once('did-finish-load', () => {
      panelRecoveryAttempts = 0
      if (shouldShow) showPanel()
    })
    panel.loadFile(PANEL_FILE).catch(error => {
      logger.log('面板恢复加载失败:', error.message)
      recoverPanel('恢复加载失败', shouldShow)
    })
  }, delay)
}

function positionPanel() {
  const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint())
  const wa = display.workArea
  panel.setBounds({
    x: wa.x,
    y: wa.y + wa.height - PANEL_HEIGHT,
    width: wa.width,
    height: PANEL_HEIGHT,
  })
}

function showPanel() {
  if (!panel) return
  // hidePanel 用 app.hide() 藏过整个应用,必须先 app.show() 解除,
  // 否则 panel.show() 只是把窗口标记为可见,屏幕上什么都不会出现
  if (isMac && !TEST_MODE) app.show()
  positionPanel()
  panel.show()
  panel.focus()
  panel.webContents.send('panel-shown')
  broadcast({ force: true })
  logger.log('面板显示:', panel.getBounds(), '可见:', panel.isVisible())
}

function hidePanel() {
  if (panel && panel.isVisible()) panel.hide()
  // macOS 上把焦点还给之前的应用,用户呼出面板前在哪就回到哪
  if (isMac && !TEST_MODE) app.hide()
  logger.log('面板隐藏')
}

function nativePasteExecutable() {
  // 开发环境从源码目录运行；打包后 helper 位于主可执行文件旁边，属于同一
  // 已签名 app bundle，避免每次粘贴拉起外部脚本。
  return app.isPackaged
    ? path.join(path.dirname(process.execPath), 'kaki-fast-paste')
    : path.join(__dirname, '../native/bin/kaki-fast-paste')
}

function deskflowExecutable() {
  // 与 kaki-fast-paste 同规则：打包后 deskflow-core 位于主可执行文件旁，并
  // 由 electron-builder 用同一身份签名，从而继承 Kaki Tools 的辅助功能授权。
  return app.isPackaged
    ? path.join(path.dirname(process.execPath), 'deskflow-core')
    : path.join(__dirname, '../native/bin/deskflow-core')
}

function settleNativePaste(requestId, result) {
  const request = nativePasteRequests.get(requestId)
  if (!request) return
  nativePasteRequests.delete(requestId)
  clearTimeout(request.timeout)
  request.resolve(result)
}

function setNativeClipboardMonitor(enabled) {
  nativeClipboardMonitorReady = !!enabled
  if (watcher) watcher.setNativeChangeMonitor(nativeClipboardMonitorReady)
}

function scheduleNativePasteRestart(reason) {
  if (!isMac || TEST_MODE || exiting || nativePasteRestartTimer || nativePasteBridge) return
  const index = Math.min(nativePasteRestartAttempts, NATIVE_PASTE_RESTART_DELAYS_MS.length - 1)
  const delay = NATIVE_PASTE_RESTART_DELAYS_MS[index]
  nativePasteRestartAttempts++
  logger.log(`原生快速粘贴将在 ${delay}ms 后恢复:`, reason)
  nativePasteRestartTimer = setTimeout(() => {
    nativePasteRestartTimer = null
    startNativePasteBridge()
  }, delay)
  nativePasteRestartTimer.unref?.()
}

function handleNativePasteBridgeStopped(child, reason) {
  if (nativePasteBridge !== child) return
  nativePasteBridge = null
  nativePasteBridgeReady = false
  setNativeClipboardMonitor(false)
  for (const [id] of nativePasteRequests) settleNativePaste(id, false)
  scheduleNativePasteRestart(reason)
}

function handleNativePasteLine(line) {
  const [status, requestId] = line.trim().split(/\s+/, 2)
  if (status === 'ready') {
    logger.log('原生快速粘贴已就绪，辅助功能:', requestId === '1' ? '已授权' : '待授权')
    nativePasteBridgeReady = true
    nativePasteRestartAttempts = 0
    setNativeClipboardMonitor(true)
    return
  }
  if (status === 'clipboard') {
    watcher?.tickFromNativeChange()
    return
  }
  if (status === 'status') return
  if (['ok', 'not-trusted', 'error'].includes(status) && requestId) {
    settleNativePaste(requestId, status === 'ok')
  }
}

function startNativePasteBridge() {
  if (!isMac || TEST_MODE || nativePasteBridge) return
  const executable = nativePasteExecutable()
  if (!fs.existsSync(executable)) {
    logger.log('原生快速粘贴未找到，保留兼容模式:', executable)
    return
  }
  try {
    const child = spawn(executable, [], { stdio: ['pipe', 'pipe', 'pipe'] })
    nativePasteBridge = child
    nativePasteBridgeReady = false
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', chunk => {
      nativePasteBuffer += chunk
      const lines = nativePasteBuffer.split(/\r?\n/)
      nativePasteBuffer = lines.pop() || ''
      lines.forEach(handleNativePasteLine)
    })
    child.stderr.on('data', chunk => logger.log('原生快速粘贴诊断:', String(chunk).trim().slice(0, 500)))
    child.on('error', error => {
      logger.log('原生快速粘贴启动失败，保留兼容模式:', error.message)
      handleNativePasteBridgeStopped(child, `启动失败: ${error.message}`)
    })
    child.on('exit', (code, signal) => {
      logger.log('原生快速粘贴已退出:', code, signal || '')
      handleNativePasteBridgeStopped(child, `退出 ${code ?? ''} ${signal || ''}`.trim())
    })
  } catch (error) {
    logger.log('原生快速粘贴初始化失败，保留兼容模式:', error.message)
  }
}

function stopNativePasteBridge() {
  if (nativePasteRestartTimer) clearTimeout(nativePasteRestartTimer)
  nativePasteRestartTimer = null
  const child = nativePasteBridge
  nativePasteBridge = null
  nativePasteBridgeReady = false
  setNativeClipboardMonitor(false)
  for (const [id] of nativePasteRequests) settleNativePaste(id, false)
  if (!child || child.killed) return
  try {
    child.stdin.end('quit\n')
    setTimeout(() => { if (!child.killed) child.kill() }, 250).unref()
  } catch {}
}

function requestNativePaste() {
  // Helper 尚在启动/预热时不写入管道；本次只走兼容路径，避免超时后
  // AppleScript 与延迟完成的原生事件各执行一次。
  if (!nativePasteBridgeReady || !nativePasteBridge || !nativePasteBridge.stdin?.writable) return Promise.resolve(false)
  const requestId = String(++nativePasteRequestId)
  return new Promise(resolve => {
    const timeout = setTimeout(() => settleNativePaste(requestId, false), NATIVE_PASTE_RESPONSE_TIMEOUT_MS)
    nativePasteRequests.set(requestId, { resolve, timeout })
    try {
      nativePasteBridge.stdin.write(`paste ${requestId}\n`, error => {
        if (error) settleNativePaste(requestId, false)
      })
    } catch {
      settleNativePaste(requestId, false)
    }
  })
}

function sendNativeBridge(command) {
  if (!nativePasteBridgeReady || !nativePasteBridge?.stdin?.writable) return false
  try { nativePasteBridge.stdin.write(`${command}\n`); return true } catch { return false }
}

function autoPasteWithCompatibilityFallback() {
  execFile('osascript', ['-e', 'tell application "System Events" to key code 9 using command down'], { timeout: 1500 }, err => {
    if (err) console.warn('[kaki] 自动粘贴失败(请在 系统设置→隐私与安全性→辅助功能 中授权):', err.message)
  })
}

// 面板隐藏、焦点回到原应用后,用常驻原生桥直接发送 ⌘V。
// osascript 仅在原生桥不可用或权限状态异常时作为兼容后备。
function autoPaste() {
  if (!settings.autoPaste || TEST_MODE) return
  // 连续选择时只保留最后一次粘贴，避免旧的自动化进程在新内容写入后重复粘贴。
  const generation = ++pasteGeneration
  if (pendingPasteTimer) clearTimeout(pendingPasteTimer)
  pendingPasteTimer = setTimeout(() => {
    pendingPasteTimer = null
    if (generation !== pasteGeneration) return
    if (isMac) {
      requestNativePaste().then(sent => {
        if (!sent && generation === pasteGeneration) autoPasteWithCompatibilityFallback()
      })
    } else if (process.platform === 'win32') {
      exec(`powershell -NoProfile -Command "$ws = New-Object -ComObject wscript.shell; $ws.SendKeys('^v')"`, () => {})
    }
  // 极速模式：面板隐藏后仅给 macOS 20ms 归还焦点，优先降低粘贴体感延迟。
  }, AUTO_PASTE_DELAY_MS)
}

function togglePanel() {
  const visible = panel && panel.isVisible()
  logger.log('面板快捷键触发,当前可见:', !!visible)
  if (visible) hidePanel()
  else showPanel()
}

// 按下排列快捷键时如果我们的面板在最前:先藏面板,等焦点回到原应用再重试
function winmanOpts() {
  return {
    onSelf: retry => {
      hidePanel()
      setTimeout(retry, 350)
    },
  }
}

function registerHotkey() {
  const candidates = [settings.hotkey, ...(settings.fallbackHotkeys || [])]
  for (const key of candidates) {
    try {
      if (globalShortcut.register(key, togglePanel)) {
        activeHotkey = key
        logger.log('面板快捷键:', key)
        return
      }
    } catch {}
  }
  logger.log('所有候选面板快捷键都注册失败,请修改 settings.json 中的 hotkey')
}

function takeRegionScreenshot() {
  if (!isMac || screenshotInProgress) {
    if (screenshotInProgress) logger.log('区域截图已在进行中，忽略重复触发')
    return
  }
  screenshotInProgress = true
  // 保留剪贴板面板的可见状态，仅暂时撤销 floating 层级；这样系统截图选框
  // 会覆盖在面板上方，用户仍能看见面板及其背后的上下文。
  const restorePanelFloating = panel && !panel.isDestroyed() && panel.isVisible()
  if (restorePanelFloating) panel.setAlwaysOnTop(false)
  // 设置/关于窗口并不是截图的主面板，继续避让系统选框。
  if (settingsWindow && !settingsWindow.isDestroyed() && settingsWindow.isVisible()) {
    settingsWindow.hide()
  }
  if (aboutWindow && !aboutWindow.isDestroyed() && aboutWindow.isVisible()) {
    aboutWindow.hide()
  }
  setTimeout(() => {
    try {
      execFile('screencapture', ['-i', '-c'], { timeout: 120000 }, error => {
        screenshotInProgress = false
        if (restorePanelFloating && panel && !panel.isDestroyed() && panel.isVisible()) {
          panel.setAlwaysOnTop(true, 'floating')
        }
        if (error) logger.log('区域截图已取消或失败:', error.message)
      })
    } catch (error) {
      screenshotInProgress = false
      if (restorePanelFloating && panel && !panel.isDestroyed() && panel.isVisible()) {
        panel.setAlwaysOnTop(true, 'floating')
      }
      logger.log('区域截图启动失败:', error.message)
    }
  }, 120)
}

function registerScreenshotHotkey() {
  if (isReservedMacShortcut(settings.screenshotHotkey)) {
    settings.screenshotHotkey = 'Command+Shift+2'
    saveSettings()
    logger.log('截图快捷键是 macOS 保留组合，已恢复默认: Command+Shift+2')
  }
  try {
    if (settings.screenshotHotkey && globalShortcut.register(settings.screenshotHotkey, takeRegionScreenshot)) {
      activeScreenshotHotkey = settings.screenshotHotkey
      logger.log('截图快捷键:', activeScreenshotHotkey)
      return
    }
  } catch {}
  activeScreenshotHotkey = null
  logger.log('截图快捷键注册失败(可能被系统或其他应用占用)')
}

function shortcutAvailable(accelerator, current) {
  if (!accelerator || typeof accelerator !== 'string') return false
  if (accelerator === current) return true
  try {
    if (globalShortcut.isRegistered(accelerator)) return false
    if (!globalShortcut.register(accelerator, () => {})) return false
    globalShortcut.unregister(accelerator)
    return true
  } catch { return false }
}

function isReservedMacShortcut(accelerator) {
  if (!isMac) return false
  const value = accelerator.replace('CommandOrControl', 'Command')
  return new Set([
    'Command+Space', 'Command+Tab', 'Command+`', 'Command+Shift+`',
    'Command+Shift+3', 'Command+Shift+4', 'Command+Shift+5',
    'Command+H', 'Command+M', 'Command+Q', 'Command+W',
  ]).has(value)
}

function updateShortcutSettings(next) {
  const panelHotkey = String(next.panelHotkey || '').trim()
  const screenshotHotkey = String(next.screenshotHotkey || '').trim()
  if (!panelHotkey || !screenshotHotkey) return { ok: false, message: '请为两个功能都设置快捷键。' }
  if (panelHotkey === screenshotHotkey) return { ok: false, message: '两个功能不能使用同一个快捷键。' }
  if (isReservedMacShortcut(panelHotkey) || isReservedMacShortcut(screenshotHotkey)) {
    return { ok: false, message: '这是 macOS 系统保留快捷键，无法可靠覆盖。请换一个组合。' }
  }
  if (!shortcutAvailable(panelHotkey, activeHotkey) || !shortcutAvailable(screenshotHotkey, activeScreenshotHotkey)) {
    return { ok: false, message: '该快捷键已被 macOS、其他应用或 Kaki 的窗口排列功能占用，请换一个组合。' }
  }
  const previous = { panel: activeHotkey, screenshot: activeScreenshotHotkey }
  try {
    if (previous.panel) globalShortcut.unregister(previous.panel)
    if (previous.screenshot) globalShortcut.unregister(previous.screenshot)
    if (!globalShortcut.register(panelHotkey, togglePanel) || !globalShortcut.register(screenshotHotkey, takeRegionScreenshot)) throw new Error('register failed')
    activeHotkey = panelHotkey
    activeScreenshotHotkey = screenshotHotkey
    settings.hotkey = panelHotkey
    settings.screenshotHotkey = screenshotHotkey
    if (!saveSettings()) throw new Error('save failed')
    if (tray) tray.setContextMenu(buildTrayMenu())
    return { ok: true, panelHotkey, screenshotHotkey }
  } catch {
    globalShortcut.unregister(panelHotkey)
    globalShortcut.unregister(screenshotHotkey)
    if (previous.panel) globalShortcut.register(previous.panel, togglePanel)
    if (previous.screenshot) globalShortcut.register(previous.screenshot, takeRegionScreenshot)
    activeHotkey = previous.panel
    activeScreenshotHotkey = previous.screenshot
    return { ok: false, message: '无法注册该快捷键，原快捷键已恢复。' }
  }
}

function openSettingsWindow() {
  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.show()
    settingsWindow.focus()
    return
  }
  settingsWindow = new BrowserWindow({
    width: 620, height: 760, minWidth: 560, minHeight: 620, show: false,
    title: 'Kaki Tools 设置', backgroundColor: '#111315',
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, sandbox: true },
  })
  settingsWindow.webContents.on('before-input-event', (event, input) => {
    if (!recordingShortcutTarget) return
    event.preventDefault()
    if (input.key === 'Escape') {
      settingsWindow.webContents.send('shortcut:recorded', { target: recordingShortcutTarget, cancelled: true })
      recordingShortcutTarget = null
      return
    }
    if (['Meta', 'Control', 'Alt', 'Shift'].includes(input.key)) return
    const key = input.key.length === 1 ? input.key.toUpperCase() : input.key
    const modifiers = []
    if (input.meta) modifiers.push('Command')
    else if (input.control) modifiers.push('Control')
    if (input.alt) modifiers.push('Alt')
    if (input.shift) modifiers.push('Shift')
    if (!modifiers.length) return
    settingsWindow.webContents.send('shortcut:recorded', { target: recordingShortcutTarget, accelerator: [...modifiers, key].join('+') })
    recordingShortcutTarget = null
  })
  settingsWindow.once('ready-to-show', () => settingsWindow?.show())
  settingsWindow.on('closed', () => { settingsWindow = null; recordingShortcutTarget = null })
  settingsWindow.loadFile(path.join(__dirname, '../renderer/settings.html'))
}

function openAboutWindow() {
  if (aboutWindow && !aboutWindow.isDestroyed()) {
    aboutWindow.show()
    aboutWindow.focus()
    return
  }
  aboutWindow = new BrowserWindow({
    width: 560, height: 670, minWidth: 500, minHeight: 600, show: false,
    title: '关于 Kaki Tools', backgroundColor: '#101214',
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, sandbox: true },
  })
  aboutWindow.once('ready-to-show', () => aboutWindow?.show())
  aboutWindow.on('closed', () => { aboutWindow = null })
  aboutWindow.loadFile(path.join(__dirname, '../renderer/about.html'))
}

function hotkeyLabel() {
  if (!activeHotkey) return '快捷键注册失败(可能被占用)'
  return '呼出快捷键: ' + activeHotkey
    .replace('CommandOrControl', isMac ? '⌘' : 'Ctrl')
    .replace('Command', '⌘').replace('Option', '⌥')
    .replace(/\+/g, ' + ')
}

function cleanupBeforeExit(reason) {
  if (exiting) return false
  exiting = true
  logger.log('退出请求:', reason)
  try {
    if (watcher) watcher.stop()
  } catch (error) {
    logger.log('退出清理警告:剪贴板监听', error.message)
  }
  watcher = null
  try { deskflowCore?.stop() } catch {}
  stopNativePasteBridge()
  try {
    if (store) store.flushSync()
  } catch (error) {
    logger.log('退出清理警告:历史保存', error.message)
  }
  try {
    globalShortcut.unregisterAll()
  } catch (error) {
    logger.log('退出清理警告:快捷键', error.message)
  }
  return true
}

function quitApp(reason = '菜单栏') {
  if (!cleanupBeforeExit(reason)) return
  try {
    if (tray) tray.destroy()
  } catch (error) {
    logger.log('退出清理警告:菜单栏', error.message)
  }
  tray = null
  try {
    if (panel && !panel.isDestroyed()) {
      panel.removeAllListeners()
      panel.destroy()
    }
  } catch (error) {
    logger.log('退出清理警告:面板', error.message)
  }
  panel = null

  // 清理和历史同步已完成，直接结束进程，避免 Electron 在隐藏菜单栏应用状态下留下僵尸实例。
  logger.log('退出执行:process.exit')
  process.exit(0)
}

process.once('SIGTERM', () => quitApp('系统终止信号'))
process.once('SIGINT', () => quitApp('终端中断信号'))

function buildTrayMenu() {
  return Menu.buildFromTemplate([
    { label: 'Kaki Tools', enabled: false },
    { label: '打开剪贴板', accelerator: activeHotkey || undefined, click: showPanel },
    { label: '区域截图', accelerator: activeScreenshotHotkey || undefined, click: takeRegionScreenshot },
    { label: '设置…', accelerator: 'CommandOrControl+,', click: openSettingsWindow },
    { type: 'separator' },
    {
      label: '窗口排列',
      submenu: [
        ...['left-half', 'right-half', 'top-half', 'bottom-half'],
        'sep',
        ...['top-left', 'top-right', 'bottom-left', 'bottom-right'],
        'sep',
        ...['left-third', 'center-third', 'right-third', 'left-two-thirds', 'right-two-thirds'],
        'sep',
        ...['maximize', 'center'],
      ].map(key => key === 'sep'
        ? { type: 'separator' }
        : {
            label: winman.LAYOUTS[key].label,
            accelerator: settings.windowManager.shortcuts[key] || undefined,
            click: () => winman.arrange(key, { ...winmanOpts(), delay: 300 }),
          }),
    },
    {
      label: '更多',
      submenu: [
        {
          label: '开机自启动', type: 'checkbox', checked: app.getLoginItemSettings().openAtLogin,
          click: item => { app.setLoginItemSettings({ openAtLogin: item.checked }); tray.setContextMenu(buildTrayMenu()) },
        },
        ...(isMac ? [{
          label: systemPreferences.isTrustedAccessibilityClient(false) ? '辅助功能：已授权' : '辅助功能：去授权',
          enabled: !systemPreferences.isTrustedAccessibilityClient(false),
          click: () => shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'),
        }] : []),
        { type: 'separator' },
        // 与设置页保持一致：清空普通历史是直接操作，不再多一层确认菜单。
        { label: '清空普通历史', click: () => store.clear() },
        { label: '关于 Kaki Tools', click: openAboutWindow },
      ],
    },
    { type: 'separator' },
    {
      label: '退出 Kaki Tools',
      click: () => quitApp('菜单栏'),
    },
  ])
}

// 授权状态变化时刷新托盘菜单里的权限提示
function watchAxStatus() {
  if (!isMac) return
  let last = systemPreferences.isTrustedAccessibilityClient(false)
  setInterval(() => {
    const now = systemPreferences.isTrustedAccessibilityClient(false)
    if (now !== last) {
      last = now
      if (tray) tray.setContextMenu(buildTrayMenu())
    }
  }, 5000)
}

function createTray() {
  const color = isMac ? [0, 0, 0] : [255, 255, 255]
  const icon = nativeImage.createEmpty()
  for (const scale of [1, 2]) {
    const png = icons.makeKIconPng(16 * scale, color)
    icon.addRepresentation({
      scaleFactor: scale,
      dataURL: 'data:image/png;base64,' + png.toString('base64'),
    })
  }
  if (isMac) icon.setTemplateImage(true)
  tray = new Tray(icon)
  tray.setToolTip('Kaki Tools — 剪贴板历史')
  tray.setContextMenu(buildTrayMenu())
  if (!isMac) tray.on('click', togglePanel)
}

function seedTestData() {
  const samples = [
    '重新帮我生成一版 PPT 大纲,风格参考上次的曲风歌词排版',
    '魂兵之戈_AI电影项目/01_项目总控/',
    'const total = items.reduce((sum, i) => sum + i.bytes, 0)',
    'https://github.com/electron/electron/releases',
    '会议纪要:周三 14:00 讨论组织架构 v9.0,记得带上项目总控文档',
    '在 macOS 上首次运行时,请在弹窗中允许 Kaki Tools 访问剪贴板',
  ]
  for (const s of samples) store.addText(s)
  store.addText('带格式示例:Markdown 标题与加粗', { html: '<h3>带格式示例</h3><b>加粗</b>' })
  const png = icons.makeSamplePng(360, 240)
  const img = nativeImage.createFromBuffer(png)
  store.addImage(img, png, 'test-image-hash-1')
  store.createBoard('常用链接')
  store.createBoard('提示词')
  const link = store.list().find(i => i.type === 'text' && i.text.startsWith('https://'))
  if (link) store.addToBoard(link.id, '常用链接')
  const meeting = store.list().find(i => i.type === 'text' && i.text.startsWith('会议纪要'))
  if (meeting) store.updateMetadata(meeting.id, { tags: ['项目', '重要'], note: '周三会前确认组织架构。' })
  // 时间错开一点,验证相对时间显示
  const now = Date.now()
  store.list().forEach((it, idx) => { it.createdAt = now - idx * 47 * 60 * 1000 })
}

const gotLock = app.requestSingleInstanceLock()
if (!gotLock) {
  // 必须用 exit 而非 quit:quit 之后 whenReady 的初始化仍会继续执行,
  // 会产生一个消费掉退出流程的僵尸实例,之后再也无法正常退出
  app.exit(0)
} else {
  app.on('second-instance', showPanel)
  app.on('activate', showPanel)

  app.whenReady().then(() => {
    if (isMac) app.dock.hide()
    if (!TEST_MODE) migrateOldData(app.getPath('userData'))
    logger.init(app.getPath('userData'))
    loadSettings()
    deskflowCore = new DeskflowCore({ userData: app.getPath('userData'), deviceName: os.hostname(), binaryPath: deskflowExecutable() })
    deskflowCore.on('status', status => {
      settingsWindow?.webContents.send('desklink:status', status)
    })
    deskflowCore.on('error', message => settingsWindow?.webContents.send('desklink:error', String(message)))
    deskflowCore.on('log', line => logger.log('deskflow:', line))
    store = new Store(app.getPath('userData'), {
      maxHistoryItems: settings.maxHistoryItems,
    })
    refreshHistorySnapshot()
    store.onChange = () => {
      refreshHistorySnapshot()
      broadcast()
    }
    createPanel()
    if (!TEST_MODE && settings.showOnLaunch !== false) {
      setTimeout(() => {
        if (panel && !panel.isVisible()) showPanel()
      }, 180)
    }

    if (TEST_MODE) {
      if (process.env.KAKI_TEST_ACTION === 'quit') {
        setTimeout(() => quitApp('自动化退出测试'), 250)
        return
      }
      if (process.env.KAKI_TEST_ACTION === 'settings') {
        setTimeout(() => openSettingsWindow(), 120)
        const waitForSettings = setInterval(async () => {
          if (!settingsWindow || settingsWindow.isDestroyed()) return
          clearInterval(waitForSettings)
          settingsWindow.webContents.once('did-finish-load', () => setTimeout(async () => {
            const image = await settingsWindow.webContents.capturePage()
            fs.writeFileSync(process.env.KAKI_SHOT || path.join(os.tmpdir(), 'kaki-settings.png'), image.toPNG())
            app.exit(0)
          }, 250))
        }, 20)
        return
      }
      if (process.env.KAKI_TEST_ACTION === 'about') {
        setTimeout(() => openAboutWindow(), 120)
        const waitForAbout = setInterval(() => {
          if (!aboutWindow || aboutWindow.isDestroyed()) return
          clearInterval(waitForAbout)
          aboutWindow.webContents.once('did-finish-load', () => setTimeout(async () => {
            const image = await aboutWindow.webContents.capturePage()
            fs.writeFileSync(process.env.KAKI_SHOT || path.join(os.tmpdir(), 'kaki-about.png'), image.toPNG())
            app.exit(0)
          }, 250))
        }, 20)
        return
      }
      if (process.env.KAKI_TEST_ACTION === 'wait-for-signal') return
      seedTestData()
      panel.webContents.once('did-finish-load', () => {
        setTimeout(async () => {
          if (process.env.KAKI_TEST_THEME) {
            const theme = JSON.stringify(process.env.KAKI_TEST_THEME)
            await panel.webContents.executeJavaScript(
              `document.querySelector('[data-theme-value=' + ${theme} + ']')?.click()`,
            )
          }
          showPanel()
          if (process.env.KAKI_TEST_ACTION === 'metadata') {
            await panel.webContents.executeJavaScript(
              "document.querySelector('.card-actions button')?.click()",
            )
          }
          setTimeout(async () => {
            try {
              const image = await panel.webContents.capturePage()
              const out = process.env.KAKI_SHOT || path.join(os.tmpdir(), 'kaki-shot.png')
              fs.writeFileSync(out, image.toPNG())
              console.log('[kaki] 截图已保存:', out)
            } catch (e) {
              console.error('[kaki] 截图失败', e)
            }
            app.exit(0)
          }, 1500)
        }, 200)
      })
      return
    }

    registerHotkey()
    registerScreenshotHotkey()
    if (settings.windowManager.enabled) {
      winman.registerShortcuts(globalShortcut, settings.windowManager.shortcuts, winmanOpts())
    }
    // 窗口排列和自动粘贴都依赖「辅助功能」权限;没有就弹系统授权对话框
    // (调用后 macOS 会把本应用加进 辅助功能 列表,用户打开开关即可)
    if (isMac) {
      const trusted = systemPreferences.isTrustedAccessibilityClient(false)
      logger.log('启动时辅助功能权限:', trusted ? '已授权' : '未授权')
      if (!trusted) setTimeout(() => systemPreferences.isTrustedAccessibilityClient(true), 1200)
    }
    startNativePasteBridge()
    createTray()
    watchAxStatus()
    watcher = new Watcher({
      onText: (text, rich) => store.addText(text, rich),
      onImage: (img, png, hash) => store.addImage(img, png, hash),
    })
    watcher.start(settings.pollIntervalMs)
    if (nativeClipboardMonitorReady) watcher.setNativeChangeMonitor(true)
  })

  ipcMain.handle('history:get', () => historySnapshot)
  ipcMain.handle('settings:get', () => ({
    panelHotkey: activeHotkey || settings.hotkey,
    screenshotHotkey: activeScreenshotHotkey || settings.screenshotHotkey,
    maxHistoryItems: settings.maxHistoryItems,
    version: app.getVersion(),
    desklink: deskflowCore?.status() || { role: 'idle', port: DEFAULT_PORT, fingerprint: '', deviceName: os.hostname() },
  }))
  ipcMain.handle('desklink:host', (_e, payload) => {
    try { return { ok: true, state: deskflowCore.startHost({ port: payload?.port }) } } catch (error) { return { ok: false, message: error.message } }
  })
  ipcMain.handle('desklink:connect', (_e, payload) => {
    try { return { ok: true, state: deskflowCore.connect(payload || {}) } } catch (error) { return { ok: false, message: error.message } }
  })
  ipcMain.handle('desklink:stop', () => {
    deskflowCore?.stop()
    return { ok: true, state: deskflowCore?.status() }
  })
  ipcMain.handle('clipboard:write', (_e, text) => {
    clipboard.writeText(String(text ?? ''))
    return { ok: true }
  })
  ipcMain.handle('settings:save-shortcuts', (_e, payload) => updateShortcutSettings(payload || {}))
  ipcMain.on('settings:record-shortcut', (_e, target) => {
    recordingShortcutTarget = ['panel-hotkey', 'screenshot-hotkey'].includes(target) ? target : null
  })
  ipcMain.on('renderer:diagnostic', (_e, message) => {
    logger.log('渲染进程诊断:', String(message).slice(0, 500))
  })
  ipcMain.handle('history:thumb', (_e, id) => {
    const item = store.get(id)
    return item && item.type === 'image' ? item.thumb || '' : ''
  })

  // opts.plain = true 时只复制纯文本;默认带上抓取到的 HTML/RTF 富文本
  function activateItem(id, opts = {}) {
    const item = store.get(id)
    if (!item) return
    if (item.type === 'text') {
      if (!opts.plain && (item.html || item.rtf)) {
        clipboard.write({ text: item.text, html: item.html, rtf: item.rtf })
      } else {
        clipboard.writeText(item.text)
      }
    } else if (item.file) {
      const img = nativeImage.createFromPath(item.file)
      if (!img.isEmpty()) clipboard.writeImage(img)
    }
    if (watcher) watcher.suppress(1500)
    hidePanel()
    autoPaste()
    // 自动粘贴优先；列表排序与渲染不应挡在回贴链路前面。
    setTimeout(() => store.touch(id), 200)
  }

  ipcMain.on('item:activate', (_e, id, opts) => activateItem(id, opts || {}))
  ipcMain.on('item:delete', (_e, id) => store.remove(id))
  ipcMain.on('item:pin', (_e, id) => store.togglePin(id))
  ipcMain.on('item:metadata', (_e, payload) => store.updateMetadata(payload?.id, payload || {}))
  ipcMain.on('history:clear', () => store.clear())
  ipcMain.on('panel:hide', hidePanel)
  ipcMain.on('app:quit', () => quitApp('面板'))

  // 卡片右键菜单
  ipcMain.on('item:context', (_e, id, currentBoard) => {
    const item = store.get(id)
    if (!item || !panel) return
    const template = []
    if (item.type === 'text') {
      // 右键的高频诉求是避免把网页、文档样式带进目标应用，所以纯文本置顶。
      template.push({ label: '粘贴为纯文本', click: () => activateItem(id, { plain: true }) })
      if (item.html || item.rtf) {
        template.push({ label: '保留格式粘贴', click: () => activateItem(id) })
      }
    } else {
      template.push({ label: '使用', click: () => activateItem(id) })
    }
    template.push({ type: 'separator' })
    const boardItems = store.boards
      .filter(b => b !== item.board)
      .map(b => ({ label: b, click: () => store.addToBoard(id, b) }))
    template.push({
      label: '添加到标签页',
      submenu: [
        ...boardItems,
        ...(boardItems.length ? [{ type: 'separator' }] : []),
        { label: '新建标签页…', click: () => panel.webContents.send('board:prompt', { mode: 'create', itemId: id }) },
      ],
    })
    template.push({
      label: '标签与备注…',
      click: () => panel.webContents.send('item:metadata:open', {
        id,
        tags: Array.isArray(item.tags) ? item.tags : [],
        note: item.note || '',
      }),
    })
    template.push({ type: 'separator' })
    if (item.board) {
      template.push({ label: `从「${item.board}」移除`, click: () => store.remove(id) })
    } else {
      template.push({ label: item.pinned ? '取消固定' : '固定', click: () => store.togglePin(id) })
      template.push({ label: '删除', click: () => store.remove(id) })
    }
    Menu.buildFromTemplate(template).popup({ window: panel })
  })

  // 标签页(tab)右键菜单
  ipcMain.on('board:context', (_e, name) => {
    if (!panel || !store.boards.includes(name)) return
    Menu.buildFromTemplate([
      { label: `重命名「${name}」…`, click: () => panel.webContents.send('board:prompt', { mode: 'rename', oldName: name }) },
      {
        label: '删除标签页',
        submenu: [{ label: `确认删除「${name}」及其中所有收藏`, click: () => store.deleteBoard(name) }],
      },
    ]).popup({ window: panel })
  })

  ipcMain.on('board:create', (_e, { name, addItemId }) => {
    const created = store.createBoard(name)
    if (created && addItemId) store.addToBoard(addItemId, created)
  })
  ipcMain.on('board:rename', (_e, { oldName, newName }) => store.renameBoard(oldName, newName))

  // 注册监听即表示无窗口时继续驻留;退出只走 quitApp 或系统退出事件。
  app.on('window-all-closed', () => {})
  app.on('before-quit', () => cleanupBeforeExit('系统'))
  app.on('will-quit', () => globalShortcut.unregisterAll())
  app.on('quit', (_e, code) => console.log('[kaki] quit, code =', code))
}
