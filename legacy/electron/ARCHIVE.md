# Electron 旧版归档

此目录保留迁移前的 Electron 源码、测试、构建工具、文档和旧安装包，包括归档时已有的本地修改。当前原生 macOS 应用在仓库根目录的 `macos/` 下；根目录的默认构建和测试不执行此归档。

`SOURCE-SNAPSHOT.json` 保存归档前源码文件的 SHA-256；`package.before-archive.json` 保留原 package.json。归档后的 package.json 只增加 private 标记并说明用途。原 `README.md` 属于旧版本资料，其命令应在本归档目录执行。

`native/deskflow` 链接至共享的可选运行库 `../deskflow/components/deskflow`（相对于归档根目录）；归档的 Deskflow 构建脚本转到`legacy/deskflow/scripts/` 中的历史组件构建工具。它不进入默认原生主包。

## 需要回看旧版时

```bash
cd legacy/electron
npm ci
npm test
# 确实需要运行或打包旧版时才执行
npm start
npm run dist
```

旧 node_modules 已移至 macOS 废纸篓保留，未清空；可按锁文件重新安装。旧版与原生版共用应用标识和正式数据目录，不能同时运行；测试仍使用隔离目录。旧版安装器与本地升级脚本仅供明确选择旧版时使用。

Electron渲染性能测试从仓库 Git HEAD 读取迁移前的 renderer/app.js 基线；未来 Git HEAD 不再包含该文件时，应提供合适的旧提交基线后再执行该归档测试。
