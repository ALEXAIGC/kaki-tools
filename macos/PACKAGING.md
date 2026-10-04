# 原生 macOS 打包

主应用使用 Swift、AppKit 和系统框架，目标为当前构建机架构、macOS 13 或更高版本。原生构建与 DMG 打包不需要 npm、Electron 或 Qt。应用图标由 `scripts/build-macos-icons.sh` 从共享几何标识生成，再从 `macos/Resources/icon.icns` 复制，面板品牌标识从 `macos/Resources/kaki-logo.png` 复制为 `Contents/Resources/kaki-logo.png`。

## 构建主应用与 DMG

在仓库根目录执行：

```bash
bash scripts/test-macos-native.sh
bash scripts/build-macos-native.sh
bash scripts/package-macos-native.sh
```

Apple Silicon 默认产物：

```text
dist/native-arm64/Kaki Tools.app
dist/native-arm64/Kaki-Tools-1.4.10-arm64.dmg
dist/native-arm64/Kaki-Tools-1.4.10-arm64.dmg.sha256
```

文件名中的版本取自应用 `Info.plist`。本地生成新版本不会删除已有版本的 DMG 或校验文件；GitHub 仅维护最新版本的发布及安装包。脚本也接受显式应用路径与输出目录：

```bash
bash scripts/package-macos-native.sh '/path/Kaki Tools.app' '/path/output'
```

DMG 包含应用、指向 `/Applications` 的链接、安装说明、签名身份校验过的可选重新授权工具和原生版使用说明；仓库存在 `LICENSE` 时一并复制。“修复截图权限.command”检查所有同标识应用实例已退出，只重置 Kaki Tools 的 ScreenCapture；“重新授权.command”同时修复辅助功能和录屏，仅用于两类旧授权都失效。工具由用户主动运行，打包过程不执行权限重置。打包前、复制后及只读挂载后，脚本验证原生构建标记、应用标识、Mach-O 架构和完整代码签名，拒绝 Electron、Qt 或内置跨屏组件。DMG 使用压缩只读 UDZO 格式，生成时执行 `hdiutil verify`、`hdiutil checksum`，再挂载核对应用与链接，并比较源应用、暂存副本和挂载副本的逐文件 SHA-256、符号链接目标与执行位清单。成功、失败或中断都会尝试卸载；若系统拒绝普通和强制卸载，脚本报告挂载位置并保留临时文件。

```bash
cd dist/native-arm64
shasum -a 256 -c Kaki-Tools-1.4.10-arm64.dmg.sha256
hdiutil verify Kaki-Tools-1.4.10-arm64.dmg
```

原生构建默认使用 `macos/Signing/local-certificate.sha1` 指定的固定本地证书。私钥保存在登录钥匙串；仓库只有公开证书和指纹。缺少证书/私钥或信任失效时构建停止，禁止自动退回临时签名。仅隔离开发编译可显式指定 `KAKI_NATIVE_IDENTITY=-`；DMG打包拒绝临时签名。

`python3 scripts/setup-macos-local-signing.py` 复用已有身份并核对公开指纹；已经固定的身份不存在时拒绝自动生成替代证书。当前证书只在当前用户的代码签名策略下受信任，不设置SSL或系统范围的根证书信任。首次没有指纹时才创建本地证书。

该包供本机使用，不等同于Apple Developer ID签名或公证。安装到其他Mac或公开分发应使用已有Developer ID身份，通过 `KAKI_NATIVE_IDENTITY` 指定，并完成Apple公证。DMG脚本保留并验证应用签名，不重新签名；这些脚本不会自动安装或替换 `/Applications`。

## 历史组件

旧版组件可从 Git 提交历史查阅。已有本地 `legacy/` 归档保留在磁盘，并从当前源码索引排除，不参与原生构建、测试和发布。
