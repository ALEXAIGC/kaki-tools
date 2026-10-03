# 原生 macOS 打包

主应用使用 Swift、AppKit 和系统框架，目标为当前构建机架构、macOS 13 或更高版本。原生构建与 DMG 打包不需要 npm、Electron、Qt 或 Deskflow。现有应用图标从 `macos/Resources/icon.icns` 复制，面板品牌标识从 `macos/Resources/kaki-logo.png` 复制为 `Contents/Resources/kaki-logo.png`。

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
dist/native-arm64/Kaki-Tools-1.0.3-arm64.dmg
dist/native-arm64/Kaki-Tools-1.0.3-arm64.dmg.sha256
```

文件名中的版本取自应用 `Info.plist`。生成新版本不会删除已有版本的 DMG 或校验文件，旧 Electron 版本元数据独立保留在 `legacy/electron/package.json`。脚本也接受显式应用路径与输出目录：

```bash
bash scripts/package-macos-native.sh '/path/Kaki Tools.app' '/path/output'
```

DMG 包含应用、指向 `/Applications` 的链接和原生版使用说明；仓库存在 `LICENSE` 时一并复制。打包前、复制后及只读挂载后，脚本验证原生构建标记、应用标识、Mach-O 架构和完整代码签名，拒绝 Electron、Qt 或内置跨屏组件。DMG 使用压缩只读 UDZO 格式，生成时执行 `hdiutil verify`、`hdiutil checksum`，再挂载核对应用与链接，并比较源应用、暂存副本和挂载副本的逐文件 SHA-256、符号链接目标与执行位清单。成功、失败或中断都会尝试卸载；若系统拒绝普通和强制卸载，脚本报告挂载位置并保留临时文件。

```bash
cd dist/native-arm64
shasum -a 256 -c Kaki-Tools-1.0.3-arm64.dmg.sha256
hdiutil verify Kaki-Tools-1.0.3-arm64.dmg
```

原生构建默认使用 ad-hoc 签名。已有 Developer ID 身份时，可在构建阶段设置 `KAKI_NATIVE_IDENTITY`；DMG 脚本保留并验证应用签名，不重新签名。公证和公开发布另行处理，这些脚本不会执行公证、安装或替换 `/Applications` 中的应用。

## 可选跨屏组件

跨屏键鼠共享独立分发为 `DeskflowRuntime.bundle`，不放入原生应用或主 DMG。用户解压 ZIP 后，在原生应用的跨屏设置中选择组件导入；应用验证其元数据、最低系统版本、架构与代码签名，再复制到用户数据目录的 `Components/`。导入不会自动启动 Deskflow。

已有 `components/deskflow/` 时，直接执行：

```bash
bash scripts/package-deskflow-component.sh
```

如需从 Deskflow 源码重建运行时，可使用已有脚本准备闭包，再打包：

```bash
# 需要 Xcode Command Line Tools、Homebrew、CMake、Ninja、Qt、OpenSSL。
DESKFLOW_REPO='/path/deskflow' bash scripts/build-deskflow.sh --rebuild
bash scripts/package-deskflow-component.sh
```

`build-deskflow.sh` 会更新 `components/deskflow/`，而组件打包脚本只读取该目录。更低的部署目标必须由 Deskflow、Qt 和所有依赖共同支持；只修改主程序的部署目标或 `Info.plist` 不能降低依赖的真实要求。

默认输出：

```text
dist/components-arm64/DeskflowRuntime.bundle
dist/components-arm64/DeskflowRuntime-arm64.zip
dist/components-arm64/DeskflowRuntime-arm64.zip.sha256
```

组件结构：

```text
DeskflowRuntime.bundle/Contents/
  Info.plist
  MacOS/deskflow-core
  Frameworks/
  PlugIns/
  Resources/qt.conf
  Resources/runtime-closure.json
  Resources/dependency-source.json  # 原运行时含此文件时保留
  Resources/Runtime-Provenance.txt
  Resources/Licenses/               # 有原始许可资产时保留
```

`Info.plist` 使用标识 `com.openclaw.kakitools.deskflow-runtime`、包类型 `BNDL`、可执行文件名 `deskflow-core`。当前已有 arm64 运行时含 29 个 Mach-O 对象，Qt 框架最低为 macOS 14.0，但 21 个其他依赖库要求 macOS 26.0，因此整个可选组件最低为 **macOS 26.0**；主应用仍为 macOS 13 起。打包脚本从所有 Mach-O 的真实部署目标自动计算组件最低系统版本，不修改二进制中的版本声明。

脚本保留原始 `qt.conf`、框架资源、符号链接、插件、install name 和 rpath；递归核对 dyld 的加载路径及祖先 rpath，确保非系统依赖均能在组件内解析。随后依次签名代码文件、框架容器和最外层 bundle，并验证完整签名。ZIP 解压后再次核对签名与依赖清单。校验文件在临时目录预先生成，bundle、ZIP 与校验文件发布失败时恢复旧产物。所有验证均为静态检查，不运行 Deskflow，也不建立网络连接。

```bash
codesign --verify --deep --strict 'dist/components-arm64/DeskflowRuntime.bundle'
cd dist/components-arm64
shasum -a 256 -c DeskflowRuntime-arm64.zip.sha256
```

组件默认使用 ad-hoc 签名；可通过 `KAKI_DESKFLOW_IDENTITY` 指定已有签名身份。脚本可接受其他运行时和输出位置：

```bash
KAKI_DESKFLOW_IDENTITY='Developer ID Application: Example' \
  bash scripts/package-deskflow-component.sh '/path/runtime' '/path/output'
```

## 来源与许可资产

组件保留现有运行时的来源记录、框架资源和版权元数据，并复制运行时中的 `Licenses/`、`LICENSE*` 与 `COPYING*`。也可提供原始许可文件目录：

```bash
DESKFLOW_LICENSE_DIR='/path/original-license-assets' \
  bash scripts/package-deskflow-component.sh
```

当前本地运行时没有单独的 `LICENSE` 或 `COPYING` 文件；生成的来源说明不能替代这些文件。对外分发组件前，应从对应源码版本补齐 Deskflow、Qt 及其他依赖的原始许可和所需源码材料。主应用图标使用仓库现有资产。组件打包不会借用其他参考项目的许可文件，也不会更改源运行时。
