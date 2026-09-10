# Kaki Tools

跨平台(macOS / Windows)个人效率小工具。
目前三个模块:**剪贴板历史**(参考 Paste)、**窗口排列**(参考 Magnet)和 **跨屏键鼠协同**(基于 Deskflow)。

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

## 模块三:跨屏键鼠协同

把鼠标滑到屏幕边缘,键盘鼠标自动切到旁边那台 Mac——整套键鼠共享由
[Deskflow](https://github.com/deskflow/deskflow) 的核心 `deskflow-core` 承担,
Kaki Tools 只负责生成配置、生成 TLS 身份、启动/停止进程和展示状态。
因此鼠标截获、事件注入、屏幕切换状态机都来自 Deskflow 的成熟实现,
不存在早期自制实现"断连后拦截本机输入"的问题。

**用法(多台 Mac 都装 Kaki Tools,同一局域网;设置页分「剪贴板」和「跨屏协同」两个标签页):**

1. 各台都先到 `系统设置 → 隐私与安全性 → 辅助功能` 里勾选 **Kaki Tools**
   (跨屏控制需要辅助功能权限;自动粘贴也共用同一授权)。
2. **主控 Mac**:「跨屏协同」标签页里点「开启主机」,然后把显示的**主机地址**和
   **主机指纹**(各带一键复制)发给其他各台。
3. **其他每台 Mac**:「跨屏协同」标签页里填「主机地址」和「主机指纹」,点「连接另一台 Mac」。
4. 连接后,把鼠标滑到主机屏幕**右边缘**即切到那台;反向滑回左边缘即切回。

### 多台机器与拖拽式布局

支持 **1 台主机 + 多台客户端**。主机端「跨屏协同」页会显示一个 **5×3 的网格**
(类似 macOS 的显示器排列),本机默认在中间,各台已连接的设备占用一个格子:

- **拖拽**设备到网格任意位置即可改变它的相对位置,改动即时生效;
- 只有**紧挨着**(上下左右相邻、中间无空格)的两台设备才能互相切换——和显示器
  「边缘相接才能切」的直觉一致;
- 新设备首次连接时,自动放到离主机最近的空格子(上/下/左/右依次),之后再手动拖到想放的位置;
- 布局会保存下来,下次开启主机时自动恢复。

因此常见布局(主机居中、四周各一台;或四台横向排成一排)都能直接拖出来。

- 端口默认 `24800`(TCP),自动配置,无需手动填写;各台机器间的防火墙需放行该端口。
- **无需填写对方电脑名**:客户端首次连接时,主机会自动接受它并写入配置(自动重启
  核心以生效),因此主机端只需要点一下「开启主机」。
- 指纹用于客户端校验主机身份、防中间人;主机侧当前为「仅加密、不校验客户端」,
  双向指纹锁定是后续增强项。
- 数据目录:`<userData>/deskflow/`(settings、server 配置、tls 证书与指纹库)。

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

跨屏键鼠协同依赖 Deskflow 的 `deskflow-core` 原生二进制。打包前先准备它:

```bash
# 需要本机已装 cmake/ninja/Qt6(brew install cmake ninja qt pkgconf)
brew install cmake ninja qt pkgconf

# 源码目录默认 ~/Downloads/deskflow_repo,可用 DESKFLOW_REPO 覆盖
npm run deskflow:build
```

该脚本会编译 `deskflow-core` 并用 `macdeployqt` 把 Qt 框架/插件打成自包含包,
放到 `native/deskflow/`;`npm run pack` / `npm run dist` 已把它接入 electron-builder
的 `extraFiles`,最终 `deskflow-core` 会位于 app 的 `Contents/MacOS/` 下并随应用一起签名,
从而继承 Kaki Tools 的辅助功能授权(与 `kaki-fast-paste` 同一机制)。

### Apple Silicon 与 Intel

构建脚本会自动跟随主机架构(`uname -m`),`deskflow-core`、`kaki-fast-paste` 和
electron-builder 都会产出**当前架构**的二进制。因此:

- **Apple Silicon (arm64)**:直接 `npm run dist`,产出 `Kaki Tools-*-arm64.dmg`
- **Intel (x86_64)**:同样直接 `npm run dist`,产出 `Kaki Tools-*-x64.dmg`

在 Intel Mac 上只需先装好工具链(`brew install cmake ninja qt pkgconf`)并
`git clone` 本仓库 + `~/Downloads/deskflow_repo`,其余和 Apple Silicon 完全一致,
无需改任何代码。原生二进制不能跨架构通用,所以**每台机器在各自架构上构建**是最省事的方式。

每次功能优化按一次软件更新发布：递增 `package.json` 版本号后运行
`npm run release:local`。该流程会在覆盖 `/Applications/Kaki Tools.app` 前后校验
完整代码签名，并把上一版放到应用数据目录的 `updates/` 下作为回退；签名异常时会停止，
不会覆盖当前应用或影响 macOS 的辅助功能授权。

### macOS 权限与稳定签名

本机已配置并信任 `Kaki Tools Dev` 代码签名证书。electron-builder 会使用它
为主应用、Helper 和 Framework 完整签名，让每次更新保持同一个 macOS
designated requirement。
因此辅助功能等隐私权限在首次授权后可跨版本沿用，不应因覆盖安装而反复请求。
本地自签名证书不使用 Apple 时间戳服务（`build.mac.timestamp: "none"`）。

- 默认签名证书 SHA-1：`9F800DA5082ED36AD5351E9AC06F75A14A5593D1`
- 证书轮换时需同步修改 `build.mac.identity`
- 其他 Mac 没有这张证书时，可临时设置 `CSC_IDENTITY_AUTO_DISCOVERY=false`
  并把 `build.mac.identity` 覆盖为 `null`
- 正式对外分发仍应改用 Apple Developer ID 并完成 notarization

更换签名证书会改变应用身份，macOS 可能要求用户重新授权一次。

## 项目结构与后续模块

```
main/            主进程
  index.js       入口:窗口/托盘/快捷键/IPC
  watcher.js     剪贴板轮询采集
  store.js       历史存储(JSON + 图片文件)
  genIcon.js     运行时生成托盘图标
  deskflow.js    跨屏键鼠协同:生成 Deskflow 配置/TLS 身份并托管 deskflow-core 进程
renderer/        面板 UI(原生 HTML/CSS/JS,无框架)
native/          原生 helper
  kaki-fast-paste  自动粘贴/剪贴板变更监控(Objective-C)
  deskflow-core    键鼠共享核心(Deskflow,编译产物)
  deskflow/        打包用:deskflow-core + Qt 框架/插件(macdeployqt 产物)
```

设计上每个功能是一个独立模块(采集 → 存储 → UI 三层分离)。后续想加的功能
(比如快捷指令、文本片段、截图 OCR 等)可以按同样的结构挂到托盘和面板上。

> 跨屏键鼠协同复用了 Deskflow(与 Synergy/Barrier 同源)的 `deskflow-core` 二进制,
> 该项目采用 MIT 协议,分发时保留其版权声明即可。

## 开发调试

- 测试模式:`KAKI_TEST=1 npx electron .` — 使用示例数据渲染面板并自动截图退出,
  不读剪贴板、不注册快捷键、不写正式数据目录。

## 性能与回归验证

列表按记录 ID 复用未变化的卡片；相对时间刷新只更新文字。图片指纹限制为 64 × 64，预览限制为 280 × 140，并保持宽高比、不放大小图。

原图 PNG 编码使用单个按需创建的工作线程，空闲 30 秒释放。原图和新缩略图异步写入；立即粘贴、收藏或退出时，对待保存的原图使用同步兜底。历史快照等待原图落盘后再保存，缩略图写入失败时保留内嵌数据。读取系统剪贴板、提取位图和生成小预览仍在主进程执行。

- `npm test`：存储、图片尺寸、后台编码、退出保存与删除竞态回归。
- `npm run test:renderer`：隔离 Electron 窗口中的卡片复用、排序、搜索与元数据检查，并与 Git HEAD 的列表实现比较重复渲染耗时。使用 500 条模拟记录，首屏 80 张卡片，不读取真实剪贴板；耗时不包含真实图标转换和图片解码。
- `npm run test:image`：使用合成 4K 图片，对比原生同步编码与工作线程编码的主线程占用，验证透明度及颜色（通道舍入差不超过 1/255）。后台编码总耗时可能更长，目标是改善操作响应。
