# Kaki Tools 原生 macOS

Swift + AppKit + SwiftUI，最低 macOS 13。默认应用不携带 Electron、Node.js、WebView、Qt、第三方 Swift 包或常驻辅助进程。旧 Electron 源码与安装包归档在 `legacy/electron/`，不参与默认构建。

## 使用

剪贴板沿用旧版黑灰橙色界面，包含左侧分类、横向卡片、底部操作栏和顶部收藏页签；右上角切换跟随系统、浅色和深色。普通历史仍最多100条，固定与收藏不计入。

- 菜单栏或 `⌘⇧V` 打开底部面板；快捷键冲突时尝试 `⌘⌥V` 和 `⌘⇧B`。
- 复制文本、富文本或图片自动记入历史；普通历史合计最多100条，固定与收藏不计入。
- 搜索内容、标签与备注；点击/回车使用，Shift点击/Shift回车纯文本，`⌘1–9` 快速使用。左右键在搜索框为空或光标到边界时选卡片，上下键始终选卡片；中文输入候选确认优先。
- 收藏是独立副本，清空普通历史不会删除收藏。卡片支持固定、标签、备注与右键菜单。
- `⌃⌥` 配合方向键、U/I/J/K、D/F/G、E/T、回车或C，使用15种窗口布局。具体快捷键在设置中修改。
- `⌘⇧2` 启动系统区域截图工具，Esc取消。成功后复制PNG并后台加入历史。
- 菜单显示全局快捷键；点击“快捷键设置…”或窗口子菜单里的“调整快捷键…”，可集中录制截图、剪贴板及各窗口布局的按键组合，再保存。
- 设置提供开机启动、外观、自动粘贴与失焦隐藏。

自动粘贴和窗口调整需要系统辅助功能权限。未授权时仍可以复制，再手动粘贴。原生版的签名身份可能与旧版不同，首次使用按系统提示授权。当前本地构建是ad-hoc签名，尚未Apple公证。可选Deskflow组件的最低系统版本由组件元数据决定，当前运行库的依赖需要macOS26。

## 数据与迁移

沿用 `~/Library/Application Support/Kaki Tools/` 的 `history.json`、`settings.json`、`images/` 和 `deskflow/`。启动前检查同应用标识的旧进程，原生实例还对数据目录加锁；请先退出旧版本。

首次读取旧历史会把历史JSON及全部图片完整备份到 `native-import-backup/`，备份完成后才裁剪超过100条的普通历史。首次备份会有一次磁盘IO成本。损坏主文件优先从 `history.backup.json` 恢复，并保留不可读原文件；两者都不可读则只读，避免写坏旧数据。首次保存设置前保留 `settings.pre-native.json`，未知设置字段也会保留。

富文本RTF保存原始字节，避免非UTF8编码和内嵌二进制内容被转码。图片由后台串行队列处理，完成写入后才提交记录；取消任务不会复活，点击未完成图片不会阻塞界面。单图限制4000万像素/160MiB，待处理图片预约预算384MiB（并非进程内存硬上限）；缩略图按需解码，缓存最多24项。旧SHA1图片与新SHA256图片第一次遇到同一内容时可能保留两条，其后按新哈希去重。

## 实现

`Main.swift` 管理应用生命周期及单实例；`AppController.swift` 连接菜单栏、浮窗、设置和功能模块。

- `HistoryStore/HistoryModels`：兼容JSON、图片事务、收藏、延迟持久化、缩略图缓存。
- `ClipboardService`：系统剪贴板变化计数；跳过密码管理器等隐私/瞬时标记；原子来源标记。轮询仅比较计数，没有变化时不读取图片或文本。
- `WindowManager`：直接调用AX接口，串行执行，检查请求代次、目标进程和窗口，设置超时，按窗口所在屏幕的逻辑工作区排版。
- `HotkeyManager`：Carbon全局快捷键；录制时暂停原绑定，结束后恢复；输入法/键盘布局感知的粘贴键。
- `DeskflowService`：可选组件的验签、原子导入、TLS身份复用、进程代次及5×3设备布局；未启用时不生成身份、不启动网络服务。

跨屏布局通过先选设备、再点空格移动。可选组件独立于主应用，不影响默认包体积；从设置选择解压后的 `DeskflowRuntime.bundle` 导入。网络实际互联还需要另一台设备验证。

## 编译与验证

使用系统Command Line Tools；原生构建不用 `npm install`。菜单栏面板沿用旧版 Kaki 品牌标识，构建直接从 `macos/Resources/` 复制图标与 `kaki-logo.png`，不依赖旧 renderer 目录。

```bash
bash scripts/build-macos-native.sh
bash scripts/test-macos-native.sh
bash scripts/package-macos-native.sh
```

测试使用临时目录和私有剪贴板，不读取真实历史、不注入系统按键、不调整其他应用窗口。涵盖旧数据迁移、100条上限、图片失败与取消、来源和变化计数、搜索/收藏/键盘操作、快捷键解析、屏幕坐标、TLS与组件导入。构建使用macOS13部署目标；隔离运行截图和性能采样用于额外检查界面。性能里的dispatch耗时仅表示调用窗口显示的时间，不代表首帧屏幕呈现时间。

`KAKI_NATIVE_TEST=1` 和 `KAKI_NATIVE_TEST_DIR=<临时目录>` 可隔离运行；`KAKI_NATIVE_TEST_ACTION` 支持 `quit`、`screenshot`、`settings`、`performance`、`panel-wait`、`settings-wait`、`wait`、`style-screenshot`、`style-wait`。`KAKI_NATIVE_TEST_THEME` 只用于隔离预览；style模式在指定临时目录下创建新的UUID子目录，不覆盖已有历史。实际系统授权、区域截图与另一台设备的跨屏控制仍应在安装后验证。
