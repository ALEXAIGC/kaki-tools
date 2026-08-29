// 窗口排列模块(Magnet 风格):全局快捷键把「当前最前面的应用窗口」
// 吸附到屏幕的某个区域。macOS 走 System Events(需要辅助功能权限,
// 与自动粘贴共用),Windows 走 user32.dll 的 MoveWindow。
const { execFile } = require('child_process')
const path = require('path')
const fs = require('fs')
const { app, screen, Notification } = require('electron')
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
  return (px as text) & "|" & (py as text) & "|" & (pw as text) & "|" & (ph as text)
end tell`

function setScript(x, y, w, h) {
  return `
tell application "System Events"
  set p to first application process whose frontmost is true
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
  if (/not allowed|assistive|1002|-1743|-25211/i.test(msg)) {
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

// opts.onSelf(retry):我们自己的面板/菜单在最前时,由调用方先让出焦点再重试
// opts.delay:执行前等待毫秒数(托盘菜单触发时给焦点归还留时间)
// 注意 osascript 不设短超时:首次运行会挂起等待系统授权弹窗,杀掉它弹窗就没了
function arrange(key, opts = {}) {
  const layout = LAYOUTS[key]
  if (!layout) return
  log(`排列请求: ${key}${opts.delay ? ' (延迟 ' + opts.delay + 'ms)' : ''}`)
  if (opts.delay) {
    const { delay, ...rest } = opts
    setTimeout(() => arrange(key, rest), delay)
    return
  }
  if (isMac) {
    execFile('osascript', ['-e', GET_SCRIPT], { timeout: 60000 }, (err, stdout) => {
      if (err) return handleMacError('读取窗口', err)
      const out = (stdout || '').trim()
      if (out === 'SELF') {
        log('最前应用是自己,让出焦点后重试')
        if (opts.onSelf) opts.onSelf(() => arrange(key))
        return
      }
      const [px, py, pw, ph] = out.split('|').map(Number)
      if (![px, py, pw, ph].every(Number.isFinite)) return log('窗口信息解析失败:', out.slice(0, 120))
      const display = screen.getDisplayMatching({ x: px, y: py, width: Math.max(pw, 1), height: Math.max(ph, 1) })
      const target = targetRect(layout.rect, display.workArea)
      execFile('osascript', ['-e', setScript(target.x, target.y, target.width, target.height)], { timeout: 60000 }, err2 => {
        if (err2) handleMacError('设置窗口', err2)
        else log('排列完成:', key)
      })
    })
  } else if (process.platform === 'win32') {
    // Windows:窗口所在屏取鼠标所在屏近似;坐标换算到物理像素
    const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint())
    const sf = display.scaleFactor || 1
    const t = targetRect(layout.rect, display.workArea)
    execFile('powershell', [
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', winPs1(),
      String(Math.round(t.x * sf)), String(Math.round(t.y * sf)),
      String(Math.round(t.width * sf)), String(Math.round(t.height * sf)),
    ], { timeout: 5000, windowsHide: true }, () => {})
  }
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

module.exports = { LAYOUTS, DEFAULT_SHORTCUTS, arrange, registerShortcuts }
