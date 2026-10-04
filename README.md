# Kaki Tools

原生 macOS 效率工具，使用 Swift、AppKit 和 SwiftUI。最低 macOS 13；当前版本 1.4.5。默认应用不包含 Electron、Node.js、WebView、Qt 或第三方 Swift 包。剪贴板普通历史最多100条，固定与收藏独立保留；窗口调整和区域截图使用系统接口。Studio 账号与素材库复用现有用户身份和工作区权限，支持搜索、多选复制引用、单项复制真实素材及批量下载。

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
- `⌘⇧B`：Studio 素材库；搜索已保存和最近生成的素材，单选或多选复制引用、复制素材、下载。
- `⌘⇧2`：拖选区域截图，Esc取消。
- `⌃⌥` + 方向键：窗口半屏；`⌃⌥↩`：铺满当前桌面的可用区域。
- 菜单栏 → 设置 → 快捷键：录制并保存各功能快捷键。

自动粘贴和窗口调整需要辅助功能授权，区域截图需要录屏授权。数据保存在 `~/Library/Application Support/Kaki Tools/`。旧历史迁移和设置保存会先保留备份。默认构建复用 `macos/Signing/local-certificate.sha1` 指定的固定本地签名证书；私钥仅在登录钥匙串中。缺少证书时构建停止，不退回临时签名。更换签名后的首次安装需重新授权；指定已有 Developer ID 可使用 `KAKI_NATIVE_IDENTITY`。

## Studio、缓存与即梦连接

素材库支持图片、视频和音频，视频使用原生预览。设置中可选择下载位置、缓存磁盘、容量和未使用清理天数；原素材按需读取，缓存复用前重新检查访问权限。CDN 错误不会误退出 Studio；退出清理失败时阻止旧会话自动恢复；迟到的失败响应不会删除并发下载的新缓存。

设置 → 账号提供即梦 CLI 官方网页或二维码授权，并按 KAKI 账号及测试/正式环境隔离关联。目前支持登录、刷新、解除关联和只读视频模型检查；Studio 生成任务调用即梦及结果回传尚未接入。CLI 单独安装，不包含在应用内。

“复制代码”需要 Studio 接收端适配，部署边界见 [Studio 集成说明](macos/STUDIO-INTEGRATION.md)。源码同步到 GitHub 不会自动部署 Studio 网站。当前原生测试共716项断言，使用模拟传输、临时数据与私有剪贴板。

## 目录

```text
macos/Sources/       当前原生实现
macos/Tests/         原生行为测试
macos/Resources/     原生图标与品牌图片
scripts/            原生编译、测试与打包工具
dist/               原生应用与安装包
legacy/             旧 Electron 与已停用跨屏组件的历史归档
```

详见 [原生说明](macos/README.md) 和 [打包说明](macos/PACKAGING.md)。旧版开发资料和当前本地修改完整保留在 [Electron归档](legacy/electron/ARCHIVE.md)，不参与默认原生构建。没有跨平台构建需求时无需安装归档中的依赖。
