# Kaki Tools

原生 macOS 效率工具，使用 Swift、AppKit 和 SwiftUI。最低 macOS 13；当前版本 1.0.3。默认应用不包含 Electron、Node.js、WebView、Qt 或第三方 Swift 包。剪贴板普通历史最多100条，固定与收藏独立保留；窗口调整和区域截图使用系统接口。Deskflow 跨屏协同作为可选组件独立分发。

## 开发与构建

使用 Xcode Command Line Tools，不需要 `npm install`：

```bash
bash scripts/test-macos-native.sh
bash scripts/build-macos-native.sh
bash scripts/package-macos-native.sh
# 编译并打开开发产物（不会安装到 /Applications）
bash scripts/run-macos-native.sh
```

若本机已有 npm，`npm start`、`npm run build`、`npm run pack`、`npm run dist`、`npm test` 都指向原生流程。根目录 package.json 仅提供命令别名，没有依赖。

默认输出在 `dist/native-<架构>/`。可用 `KAKI_NATIVE_OUTPUT_DIR` 指定构建输出目录。测试使用临时目录、私有剪贴板，不调整真实窗口。打包不会安装或替换当前应用。

## 常用操作

- `⌘⇧V`：剪贴板面板；搜索文本、备注和标签，按类别筛选。
- `⌘⇧2`：拖选区域截图，Esc取消。
- `⌃⌥` + 方向键：窗口半屏；`⌃⌥↩`：铺满当前桌面的可用区域。
- 菜单栏 → 快捷键设置：录制并保存各功能快捷键。

自动粘贴和窗口调整需要辅助功能授权，区域截图需要录屏授权。数据保存在 `~/Library/Application Support/Kaki Tools/`。旧历史迁移和设置保存会先保留备份。当前本地构建使用 ad-hoc 签名，重建后可能需要重新授权；指定已有稳定签名身份可使用 `KAKI_NATIVE_IDENTITY`。

## 目录

```text
macos/Sources/       当前原生实现
macos/Tests/         原生行为测试
macos/Resources/     原生图标与品牌图片
scripts/            原生编译、测试、打包与可选组件工具
components/         可选 Deskflow 运行库（生成文件，不进入主应用）
dist/               原生应用、安装包和可选组件产物
legacy/electron/    旧版源码、测试、图标工具与安装包归档
```

可选跨屏组件：

```bash
# 如需从 Deskflow 源码重建，先准备运行库
DESKFLOW_REPO='/path/deskflow' bash scripts/build-deskflow.sh --rebuild
bash scripts/package-deskflow-component.sh
```

详见 [原生说明](macos/README.md) 和 [打包说明](macos/PACKAGING.md)。旧版开发资料和当前本地修改完整保留在 [Electron归档](legacy/electron/ARCHIVE.md)，不参与默认原生构建。没有跨平台构建需求时无需安装归档中的依赖。
