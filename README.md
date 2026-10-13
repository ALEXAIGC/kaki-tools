# Kaki Tools

原生 macOS 效率工具，使用 Swift、AppKit 和 SwiftUI。最低 macOS 13；当前源码版本 1.5.12。默认应用不包含 Electron、Node.js、WebView、Qt 或第三方 Swift 包。剪贴板普通历史最多100条，固定与收藏独立保留；窗口调整和区域截图使用系统接口。Studio 账号与素材库复用现有用户身份和工作区权限，支持搜索、多选复制引用、单项复制真实素材及批量下载。

安装包见 [最新发布](https://github.com/ALEXAIGC/kaki-tools/releases/latest)。当前发布为 Apple Silicon、macOS 13 或更高版本。

## 开发与构建

使用 Xcode Command Line Tools，不需要 `npm install`：

```bash
bash scripts/test-macos-native.sh
bash scripts/build-macos-native.sh
bash scripts/package-macos-native.sh
# 编译并打开开发产物（不会安装到 /Applications）
bash scripts/run-macos-native.sh
```

若本机已有 npm，`npm start`、`npm run build`、`npm run pack`、`npm run dist`、`npm test` 都指向原生流程。根目录 package.json 提供命令别名和统一版本号，没有依赖。构建自动从该版本号生成应用版本和构建编号。

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

设置 → 账号与连接提供 Studio 与即梦品牌卡片。即梦入口统一使用常规 `dreamina` CLI，提供安装、显式更新、登录、检测和连接 Studio 工作区；按运行时五种视频方式验证兼容性，不固定到某个旧版本。CLI 独立安装，不包含在应用内。Tools 登录本人 KAKI 账号，再由本人授权本机即梦登录并连接目标 Studio 工作区；切换站点、账号或工作区后须重新连接。画布 CLI 的授权不用于此生成通道，账号页不再展示两套入口。

“复制代码”需要 Studio 接收端适配，部署边界见 [Studio 集成说明](macos/STUDIO-INTEGRATION.md)。源码同步到 GitHub 不会自动部署 Studio 网站。1.5.0候选通过1303项原生断言，使用模拟传输、临时数据、真实解码小样与私有剪贴板；官方 CLI 在隔离目录安装验证通过。1.5.1更新检测截止时间与新版Device Flow登录，授权码只在当前会话显示，取消与失败可重试。真实 Studio 登录、CLI 关联及五方式付费出片仍待实机验收。另一台 Mac 的实际屏幕授权仍需在目标机器验证；设置 → 权限与关于可复制截图诊断。

## 目录

```text
macos/Sources/       当前原生实现
macos/Tests/         原生行为测试
macos/Resources/     原生图标与品牌图片
scripts/            原生编译、测试与打包工具
dist/               原生应用与安装包
```

详见 [原生说明](macos/README.md) 和 [打包说明](macos/PACKAGING.md)。main 保留当前原生实现，GitHub 仅维护最新安装包发布；历史实现可通过 Git 提交历史查阅。已有本地 `legacy/` 归档保留在磁盘，并由 `.gitignore` 排除。
