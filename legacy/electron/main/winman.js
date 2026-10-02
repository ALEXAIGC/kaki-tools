// 窗口排列模块(Magnet 风格):全局快捷键把「当前最前面的应用窗口」
// 吸附到屏幕的某个区域。macOS 优先常驻原生 AX 助手,回退 System Events(需要辅助功能权限,
// 与自动粘贴共用),Windows 走 user32.dll 的 MoveWindow。
const { execFile } = require('child_process')
const path = require('path')
const fs = require('fs')
const { app, screen, Notification, systemPreferences } = require('electron')
const { log } = require('./log')

const isMac = process.platform === 'darwin'

// rect = [x, y, w, h],均为工作区(去掉菜单栏/Dock/任务栏)的比例
const LAYOUTS = {
  'left-half': { label: '左半屏', rect: [0, 0, 0.5, 1] },
  'right-half': { label: '右半屏', rect: [0.5, 0, 0.5, 1] },
  'top-half': { label: '上半屏', rect: [0, 0, 1, 0.5] },
  'bottom-half': { label: '下半屏', rect: [0, 0.5, 1, 0.5] },
  'top-left': { label: '左上 1/4', rect: [0, 0, 0.5, 0.5] },
  'top-right': { label: '右上 1/4', rect: [0.5, 0, 0.5, 0.5] },
  'bottom-left': { label: '左下 1/4', rect: [0, 0.5, 0.5, 0.5] },
  'bottom-right': { label: '右下 1/4', rect: [0.5, 0.5, 0.5, 0.5] },
  'left-third': { label: '左 1/3', rect: [0, 0, 1 / 3, 1] },
  'center-third': { label: '中 1/3', rect: [1 / 3, 0, 1 / 3, 1] },
  'right-third': { label: '右 1/3', rect: [2 / 3, 0, 1 / 3, 1] },
  'left-two-thirds': { label: '左 2/3', rect: [0, 0, 2 / 3, 1] },
  'right-two-thirds': { label: '右 2/3', rect: [1 / 3, 0, 2 / 3, 1] },
  'maximize': { label: '最大化', rect: [0, 0, 1, 1] },
  'center': { label: '居中', rect: [0.125, 0.1, 0.75, 0.8] },
}

const DEFAULT_SHORTCUTS = {
  'left-half': 'Control+Alt+Left',
  'right-half': 'Control+Alt+Right',
  'top-half': 'Control+Alt+Up',
  'bottom-half': 'Control+Alt+Down',
  'top-left': 'Control+Alt+U',
  'top-right': 'Control+Alt+I',
  'bottom-left': 'Control+Alt+J',
  'bottom-right': 'Control+Alt+K',
  'left-third': 'Control+Alt+D',
  'center-third': 'Control+Alt+F',
  'right-third': 'Control+Alt+G',
  'left-two-thirds': 'Control+Alt+E',
  'right-two-thirds': 'Control+Alt+T',
  'maximize': 'Control+Alt+Return',
  'center': 'Control+Alt+C',
}

// 读取最前窗口的位置和大小;如果最前面的是我们自己(面板开着),返回 SELF
const GET_SCRIPT = `
tell application "System Events"
  set p to first application process whose frontmost is true
  if name of p is "Kaki Tools" or name of p is "Electron" then return "SELF"
  set win to window 1 of p
  set {px, py} to position of win
  set {pw, ph} to size of win
  return (unix id of p as text) & "|" & (px as text) & "|" & (py as text) & "|" & (pw as text) & "|" & (ph as text)
end tell`

function setScript(pid, x, y, w, h) {
  return `
tell application "System Events"
  set p to first application process whose unix id is ${pid}
  if frontmost of p is false then return "STALE"
  set win to window 1 of p
  set size of win to {${w}, ${h}}
  set position of win to {${x}, ${y}}
  set size of win to {${w}, ${h}}
end tell`
}

const PS_SCRIPT = `param([int]$px,[int]$py,[int]$pw,[int]$ph)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class KakiWin {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
}
"@
$hwnd = [KakiWin]::GetForegroundWindow()
[KakiWin]::ShowWindow($hwnd, 9) | Out-Null
[KakiWin]::MoveWindow($hwnd, $px, $py, $pw, $ph, $true) | Out-Null
`

function targetRect(frac, wa) {
  return {
    x: Math.round(wa.x + frac[0] * wa.width),
    y: Math.round(wa.y + frac[1] * wa.height),
    width: Math.round(frac[2] * wa.width),
    height: Math.round(frac[3] * wa.height),
  }
}

let warnedPermission = false
function handleMacError(stage, err) {
  const msg = String(err && err.message || err)
  log(`窗口排列失败@${stage}:`, msg.slice(0, 300))
  if (/not allowed|assistive|accessibility|permission denied|1002|-1743|-25211/i.test(msg)) {
    if (!warnedPermission) {
      warnedPermission = true
      new Notification({
        title: 'Kaki Tools 需要辅助功能权限',
        body: '请到 系统设置 → 隐私与安全性 → 辅助功能 中允许 Kaki Tools,窗口排列才能生效。',
      }).show()
    }
  }
}

let ps1Path = null
function winPs1() {
  if (!ps1Path) {
    ps1Path = path.join(app.getPath('userData'), 'arrange-window.ps1')
    fs.writeFileSync(ps1Path, PS_SCRIPT)
  }
  return ps1Path
}

// 一个操作贯穿延迟、读取窗口、让出焦点和设置窗口;重试不能创建新的请求。
// 这样较慢的旧读取或授权回调不会覆盖用户随后按下的布局。
let requestGeneration = 0
let pendingTimer = null
let activeChild = null
let permissionWait = null
let permissionResume = null
let nativeRequester = null

// requester(command, payload) -> Promise<{status, token?, pid?, rect?, message?}>
// snapshot 的 unavailable/unsupported 可回退;apply 发出后任何失败都不重放。
function setNativeRequester(requester) {
  nativeRequester = typeof requester === 'function' ? requester : null
}

function isCurrent(generation) {
  return generation === requestGeneration
}

function hasAccessibilityPermission() {
  try {
    return !systemPreferences || !systemPreferences.isTrustedAccessibilityClient ||
      systemPreferences.isTrustedAccessibilityClient(false)
  } catch { return false }
}

function cancelPending() {
  if (pendingTimer !== null) {
    clearTimeout(pendingTimer)
    pendingTimer = null
  }
  permissionResume = null
  // 首次授权时保留正在等待系统弹窗的读取进程。它返回后只启动最新请求。
  // 已获授权的读取/设置进程可取消,无需让旧进程继续占用资源。
  if (activeChild && !activeChild.waitingPermission) {
    try { if (activeChild.process) activeChild.process.kill() } catch {}
    activeChild = null
  }
}

function runAppleScript(generation, stage, script, callback) {
  if (!isCurrent(generation)) return
  if (stage === '读取窗口' && permissionWait) {
    permissionResume = { generation, run: () => runAppleScript(generation, stage, script, callback) }
    return
  }
  const child = { process: null, waitingPermission: stage === '读取窗口' && !hasAccessibilityPermission() }
  activeChild = child
  if (child.waitingPermission) permissionWait = child
  child.process = execFile('osascript', ['-e', script], { timeout: 60000 }, (err, result) => {
    if (activeChild === child) activeChild = null
    if (permissionWait === child) {
      permissionWait = null
      const resume = permissionResume
      permissionResume = null
      if (resume && isCurrent(resume.generation)) resume.run()
    }
    if (isCurrent(generation)) callback(err, result)
  })
}

function validSnapshot(snapshot) {
  if (!snapshot || !Number.isInteger(snapshot.pid) || snapshot.pid <= 0) return false
  const rect = snapshot.rect
  return rect && [rect.x, rect.y, rect.width, rect.height].every(Number.isFinite) &&
    rect.width > 0 && rect.height > 0
}

function destination(layout, rect) {
  const display = screen.getDisplayMatching(rect)
  return targetRect(layout.rect, display.workArea)
}

function retrySelf(key, generation, opts) {
  log('最前应用是自己,让出焦点后重试')
  if (!opts.onSelf) return
  let retried = false
  opts.onSelf(() => {
    if (retried || !isCurrent(generation)) return
    retried = true
    runMac(key, generation, {})
  })
}

function arrangeAppleScript(key, generation, opts) {
  runAppleScript(generation, '读取窗口', GET_SCRIPT, (err, stdout) => {
    if (err) return handleMacError('读取窗口', err)
    const out = (stdout || '').trim()
    if (out === 'SELF') return retrySelf(key, generation, opts)
    const [pid, x, y, width, height] = out.split('|').map(Number)
    const rect = { x, y, width, height }
    if (out.split('|').length !== 5 || !validSnapshot({ pid, rect })) {
      return log('窗口信息解析失败:', out.slice(0, 120))
    }
    const target = destination(LAYOUTS[key], rect)
    runAppleScript(generation, '设置窗口', setScript(pid, target.x, target.y, target.width, target.height), (err2, result) => {
      if (err2) handleMacError('设置窗口', err2)
      else if ((result || '').trim() === 'STALE') log('排列取消: 前台应用已切换')
      else log('排列完成:', key)
    })
  })
}

function nativeError(stage, result) {
  handleMacError(stage, result && (result.message || result.status) || '原生窗口请求失败')
}

function runMac(key, generation, opts) {
  if (!isCurrent(generation)) return
  const requester = nativeRequester
  if (!requester) return arrangeAppleScript(key, generation, opts)
  Promise.resolve().then(() => {
    if (isCurrent(generation)) return requester('window-snapshot', { generation })
  }).then(snapshot => {
    if (!isCurrent(generation)) return
    // 只在助手明确未处理读取请求时回退。设置已发出后不能重复移动窗口。
    if (!snapshot || snapshot.status === 'unsupported' || snapshot.status === 'unavailable') {
      return arrangeAppleScript(key, generation, opts)
    }
    if (snapshot.status === 'self') return retrySelf(key, generation, opts)
    if (snapshot.status !== 'ok') return nativeError('读取窗口', snapshot)
    if (!validSnapshot(snapshot) || snapshot.token === undefined || snapshot.token === null || snapshot.token === '') {
      return nativeError('读取窗口', { message: '原生窗口信息无效' })
    }
    const rect = destination(LAYOUTS[key], snapshot.rect)
    return Promise.resolve(requester('window-apply', {
      generation, token: snapshot.token, pid: snapshot.pid, rect,
    })).then(result => {
      if (!isCurrent(generation)) return
      if (result && result.status === 'ok') log('排列完成:', key)
      else if (result && result.status === 'stale') log('排列取消: 前台窗口已切换')
      else nativeError('设置窗口', result)
    })
  }).catch(err => { if (isCurrent(generation)) handleMacError('原生窗口', err) })
}

// opts.onSelf(retry):面板/菜单在最前时,先让出焦点再重试。
// opts.delay:托盘菜单触发时给焦点归还留时间。
// AppleScript 不使用短超时,避免首次授权的系统弹窗被提前取消。
function arrange(key, opts = {}) {
  if (!LAYOUTS[key]) return
  const generation = ++requestGeneration
  cancelPending()
  log(`排列请求: ${key}${opts.delay ? ' (延迟 ' + opts.delay + 'ms)' : ''}`)
  const run = () => {
    if (!isCurrent(generation)) return
    if (isMac) return runMac(key, generation, opts)
    if (process.platform === 'win32') {
      const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint())
      const sf = display.scaleFactor || 1
      const t = targetRect(LAYOUTS[key].rect, display.workArea)
      const child = { process: null, waitingPermission: false }
      activeChild = child
      child.process = execFile('powershell', [
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', winPs1(),
        String(Math.round(t.x * sf)), String(Math.round(t.y * sf)),
        String(Math.round(t.width * sf)), String(Math.round(t.height * sf)),
      ], { timeout: 5000, windowsHide: true }, () => {
        if (activeChild === child) activeChild = null
      })
    }
  }
  if (Number.isFinite(opts.delay) && opts.delay > 0) {
    pendingTimer = setTimeout(() => { pendingTimer = null; run() }, opts.delay)
  } else run()
}

function registerShortcuts(globalShortcut, shortcuts, opts) {
  const failed = []
  let ok = 0
  for (const [key, accel] of Object.entries(shortcuts)) {
    if (!accel || !LAYOUTS[key]) continue
    try {
      if (globalShortcut.register(accel, () => { log('快捷键触发:', accel, '→', key); arrange(key, opts) })) ok++
      else failed.push(`${key}=${accel}`)
    } catch {
      failed.push(`${key}=${accel}`)
    }
  }
  log(`窗口排列快捷键注册: 成功 ${ok} 个` + (failed.length ? `,失败: ${failed.join(', ')}` : ''))
}

module.exports = { LAYOUTS, DEFAULT_SHORTCUTS, arrange, registerShortcuts, setNativeRequester }
