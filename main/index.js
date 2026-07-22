const { app, BrowserWindow, globalShortcut, Tray, Menu, ipcMain, screen, clipboard, nativeImage, systemPreferences, shell } = require('electron')
const path = require('path')
const fs = require('fs')
const os = require('os')
const { exec } = require('child_process')
const Store = require('./store')
const Watcher = require('./watcher')
const icons = require('./genIcon')
const winman = require('./winman')
const logger = require('./log')

const TEST_MODE = process.env.KAKI_TEST === '1'
const isMac = process.platform === 'darwin'
const PANEL_HEIGHT = 340

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
let tray = null
let store = null
let watcher = null
let settings = null
let activeHotkey = null

function loadSettings() {
  const file = path.join(app.getPath('userData'), 'settings.json')
  const defaults = {
    // 注册失败(比如快捷键已被 Paste 等软件占用)时,依次尝试后备快捷键
    hotkey: 'CommandOrControl+Shift+V',
    fallbackHotkeys: [isMac ? 'Command+Option+V' : 'Control+Alt+V', 'CommandOrControl+Shift+B'],
    maxTextItems: 500,
    maxImageItems: 100,
    hideOnBlur: true,
    pollIntervalMs: 700,
    // 选中条目后自动在原应用里执行粘贴(macOS 首次需要授予「辅助功能」权限)
    autoPaste: true,
    // 窗口排列模块(Magnet 风格),快捷键可逐个覆盖或设为 null 停用
    windowManager: { enabled: true, shortcuts: winman.DEFAULT_SHORTCUTS },
  }
  try {
    const loaded = JSON.parse(fs.readFileSync(file, 'utf8'))
    settings = { ...defaults, ...loaded }
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

function serialize() {
  return {
    boards: store.boards,
    items: store.list().map(i => ({
      id: i.id,
      type: i.type,
      pinned: !!i.pinned,
      board: i.board,
      hasRich: !!(i.html || i.rtf),
      createdAt: i.createdAt,
      text: i.type === 'text' ? String(i.text).slice(0, 3000) : undefined,
      chars: i.type === 'text' ? i.text.length : undefined,
      thumb: i.thumb,
      size: i.size,
    })),
  }
}

function broadcast() {
  if (panel && !panel.isDestroyed()) {
    panel.webContents.send('history:updated', serialize())
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
  panel.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true })
  panel.setAlwaysOnTop(true, 'pop-up-menu')
  panel.loadFile(path.join(__dirname, '../renderer/index.html'))
  panel.on('blur', () => {
    if (settings.hideOnBlur && !TEST_MODE) hidePanel()
  })
  panel.webContents.on('did-finish-load', broadcast)
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
  broadcast()
  logger.log('面板显示:', panel.getBounds(), '可见:', panel.isVisible())
}

function hidePanel() {
  if (panel && panel.isVisible()) panel.hide()
  // macOS 上把焦点还给之前的应用,用户呼出面板前在哪就回到哪
  if (isMac && !TEST_MODE) app.hide()
  logger.log('面板隐藏')
}

// 面板隐藏、焦点回到原应用后,模拟按下 粘贴 快捷键
function autoPaste() {
  if (!settings.autoPaste || TEST_MODE) return
  setTimeout(() => {
    if (isMac) {
      exec(`osascript -e 'tell application "System Events" to keystroke "v" using command down'`, err => {
        if (err) console.warn('[kaki] 自动粘贴失败(请在 系统设置→隐私与安全性→辅助功能 中授权):', err.message)
      })
    } else if (process.platform === 'win32') {
      exec(`powershell -NoProfile -Command "$ws = New-Object -ComObject wscript.shell; $ws.SendKeys('^v')"`, () => {})
    }
  }, 250)
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

function hotkeyLabel() {
  if (!activeHotkey) return '快捷键注册失败(可能被占用)'
  return '呼出快捷键: ' + activeHotkey
    .replace('CommandOrControl', isMac ? '⌘' : 'Ctrl')
    .replace('Command', '⌘').replace('Option', '⌥')
    .replace(/\+/g, ' + ')
}

function buildTrayMenu() {
  return Menu.buildFromTemplate([
    { label: 'Kaki Tools — 剪贴板历史', enabled: false },
    { label: hotkeyLabel(), enabled: false },
    { type: 'separator' },
    { label: '打开面板', click: showPanel },
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
      label: '开机自启动',
      type: 'checkbox',
      checked: app.getLoginItemSettings().openAtLogin,
      click: item => {
        app.setLoginItemSettings({ openAtLogin: item.checked })
        tray.setContextMenu(buildTrayMenu())
      },
    },
    ...(isMac ? [{
      label: systemPreferences.isTrustedAccessibilityClient(false)
        ? '辅助功能权限:已授权 ✓'
        : '辅助功能权限:未授权(点击去设置)',
      enabled: !systemPreferences.isTrustedAccessibilityClient(false),
      click: () => shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'),
    }] : []),
    { type: 'separator' },
    {
      // 后台应用弹模态对话框会不可见且卡住退出流程,改用子菜单二次确认
      label: '清空历史',
      submenu: [
        { label: '确认清空剪贴板历史(含固定;标签页收藏保留)', click: () => store.clear() },
      ],
    },
    { type: 'separator' },
    {
      label: '退出 Kaki Tools',
      click: () => {
        app.quit()
        // 若有任何东西挡住正常退出,1 秒后强制退出兜底
        setTimeout(() => app.exit(0), 1000)
      },
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

  app.whenReady().then(() => {
    if (isMac) app.dock.hide()
    if (!TEST_MODE) migrateOldData(app.getPath('userData'))
    logger.init(app.getPath('userData'))
    loadSettings()
    store = new Store(app.getPath('userData'), {
      maxTextItems: settings.maxTextItems,
      maxImageItems: settings.maxImageItems,
    })
    store.onChange = broadcast
    createPanel()

    if (TEST_MODE) {
      seedTestData()
      panel.webContents.once('did-finish-load', () => {
        setTimeout(async () => {
          showPanel()
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
    createTray()
    watchAxStatus()
    watcher = new Watcher({
      onText: (text, rich) => store.addText(text, rich),
      onImage: (img, png, hash) => store.addImage(img, png, hash),
    })
    watcher.start(settings.pollIntervalMs)
  })

  ipcMain.handle('history:get', () => serialize())

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
    store.touch(id)
    hidePanel()
    autoPaste()
  }

  ipcMain.on('item:activate', (_e, id, opts) => activateItem(id, opts || {}))
  ipcMain.on('item:delete', (_e, id) => store.remove(id))
  ipcMain.on('item:pin', (_e, id) => store.togglePin(id))
  ipcMain.on('panel:hide', hidePanel)

  // 卡片右键菜单
  ipcMain.on('item:context', (_e, id, currentBoard) => {
    const item = store.get(id)
    if (!item || !panel) return
    const template = []
    if (item.type === 'text') {
      template.push(
        { label: '使用(带格式)', enabled: !!(item.html || item.rtf), click: () => activateItem(id) },
        { label: '使用(纯文本)', click: () => activateItem(id, { plain: true }) },
      )
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

  app.on('window-all-closed', e => e.preventDefault())
  app.on('before-quit', () => { console.log('[kaki] before-quit'); if (store) store.flush() })
  app.on('will-quit', () => { console.log('[kaki] will-quit'); globalShortcut.unregisterAll() })
  app.on('quit', (_e, code) => console.log('[kaki] quit, code =', code))
}
