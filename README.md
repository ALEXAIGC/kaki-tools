# Kaki Tools

跨平台(macOS / Windows)个人效率小工具。
目前两个模块:**剪贴板历史**(参考 Paste)和 **窗口排列**(参考 Magnet)。

## 模块二:窗口排列

全局快捷键把当前应用窗口吸附到屏幕区域(基于窗口所在屏幕的工作区),
也可从托盘菜单「窗口排列」里点选。macOS 需要「辅助功能」权限(与自动粘贴共用)。

| 快捷键(Mac 为 ⌃⌥) | 动作 |
| --- | --- |
| `⌃⌥ ←` `→` `↑` `↓` | 左/右/上/下半屏 |
| `⌃⌥ U` `I` `J` `K` | 左上/右上/左下/右下 1/4 |
| `⌃⌥ D` `F` `G` | 左/中/右 1/3 |
| `⌃⌥ E` `T` | 左/右 2/3 |
| `⌃⌥ ↵` | 最大化(填满工作区) |
| `⌃⌥ C` | 居中(约 3/4 大小) |

Windows 上把 ⌃⌥ 换成 `Ctrl+Alt`。在 `settings.json` 的 `windowManager.shortcuts`
里可逐个改键(Electron Accelerator 格式),设为 `null` 停用某个动作;
`windowManager.enabled: false` 整体关闭模块。

## 模块一:剪贴板历史

- 常驻菜单栏(mac)/ 系统托盘(Windows),后台自动记录复制过的**文本和图片**
- 全局快捷键 `⌘⇧V` / `Ctrl+Shift+V` 呼出底部面板(若被 Paste 等软件占用,自动改用 `⌘⌥V` / `Ctrl+Alt+V`,托盘菜单里会显示当前生效的快捷键)
- 搜索历史、按 文本/图片/已固定 筛选
- **标签页收藏**:顶部「＋」新建标签页;卡片右键 →「添加到标签页」永久保存(不受
  条数清理影响,清空历史也不动它);标签页右键可重命名/删除
- **纯文本 / 带格式复制**:复制时自动抓取 HTML/RTF 富文本(卡片角标「富文本」);
  使用时默认带完整格式,`⇧+点击` / `⇧+↵` / 右键菜单可选「纯文本」
- 点击卡片或按 `Enter` → 复制该条目、关闭面板并**自动粘贴回原应用**
  (macOS 首次会请求「辅助功能」权限;拒绝则退化为只复制,可手动 `⌘V`)
- `⌘1`–`⌘9`(Windows 为 `Ctrl+1-9`)直接使用面板中第 1–9 张卡片,卡片底部有编号提示
- `←` `→` 选择卡片,`Esc` 关闭,滚轮横向滚动
- 卡片悬停可 **固定**(不会被自动清理)或 **删除**;托盘菜单可一键清空
- 历史保存在本地,重启不丢失;默认保留 500 条文本 + 100 张图片
- 托盘菜单可开启「开机自启动」

## 运行

```bash
cd kaki-tools
npm install
npm start
```

> **macOS 首次运行**:新版 macOS 会弹窗询问是否允许访问剪贴板,请选择「始终允许」,
> 否则无法记录历史(也可在 系统设置 → 隐私与安全性 中修改)。

## 配置

配置文件在首次运行后生成:

- macOS: `~/Library/Application Support/Kaki Tools/settings.json`
- Windows: `%APPDATA%/Kaki Tools/settings.json`

```jsonc
{
  "hotkey": "CommandOrControl+Shift+V",  // 呼出快捷键(Electron Accelerator 格式)
  "fallbackHotkeys": ["Command+Option+V"], // 主快捷键被占用时的候补
  "maxTextItems": 500,                    // 文本条数上限(固定的不计入)
  "maxImageItems": 100,                   // 图片张数上限
  "hideOnBlur": true,                     // 面板失焦自动隐藏
  "pollIntervalMs": 700,                  // 剪贴板轮询间隔
  "autoPaste": true                       // 选中后自动粘贴回原应用(需辅助功能权限)
}
```

历史数据在同目录的 `history.json` 与 `images/` 中,删除即重置。

## 打包安装包

```bash
npm i -D electron-builder
npm run dist   # mac 上产出 .dmg;Windows 安装包需在 Windows 机器(或 CI)上执行产出 .exe
```

## 项目结构与后续模块

```
main/            主进程
  index.js       入口:窗口/托盘/快捷键/IPC
  watcher.js     剪贴板轮询采集
  store.js       历史存储(JSON + 图片文件)
  genIcon.js     运行时生成托盘图标
renderer/        面板 UI(原生 HTML/CSS/JS,无框架)
```

设计上每个功能是一个独立模块(采集 → 存储 → UI 三层分离)。后续想加的功能
(比如快捷指令、文本片段、截图 OCR 等)可以按同样的结构挂到托盘和面板上。

## 开发调试

- 测试模式:`KAKI_TEST=1 npx electron .` — 使用示例数据渲染面板并自动截图退出,
  不读剪贴板、不注册快捷键、不写正式数据目录。
