> 已停用的历史运行库，不参与当前应用。

# 可选跨屏运行库

`deskflow/` 是本地生成的 Deskflow 与 Qt 运行库，供 `scripts/package-deskflow-component.sh` 单独打包；不参与原生主应用编译。`bin/` 是本地开发用 Deskflow 二进制。两者都不进入源码版本控制。

运行 `DESKFLOW_REPO=/path/deskflow bash scripts/build-deskflow.sh --rebuild` 准备运行库。系统要求、签名检查及许可资产详见 `../PACKAGING.before-universal-control.md`。

旧版归档通过 `../electron/native/deskflow` 符号链接使用此运行库，避免保留重复的82 MiB副本。
