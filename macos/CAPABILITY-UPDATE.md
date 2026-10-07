# 本机设备能力更新候选

独立 Tools 仓库，从远端 main `5d6f46cb5fa9eaf2123831b320ac9ce80160fe46`（1.5.10）开发。不修改版本、应用标识、签名配置或 Studio。

## 用户操作

1. 在账号连接页展开即梦。原设备若暂停或断开，用户先单独选择连接。
2. 点击「检测并更新设备能力」。验证当前工作区/账号/环境、已批准设备 id/epoch、CLI 原授权路径及完整 SHA-256；前后核验文件身份。仅运行本机 help 与既有只读登录态检查，不注册、更新、恢复连接或生成。
3. 核对当前版本、当前/新增/移除及确认后的原始型号列表。会员资格独立于型号能力；VIP 错误不会降级、换渠道或重投。
4. 点击「确认更新设备能力」。只调用 capabilities，保留设备 id/epoch/secret、断开偏好与原 journal。成功后只缓存公开能力。
5. 丢响应或服务器错误后重新检测，页面显示「确认重试原请求」，使用持久化原 payload 与 expectedRevision，包含重启恢复。409 读取 catalog 的原设备最新公开版本并清除旧预览，用户重新检测、确认后才能再次写入；不自动提高 revision 覆盖。

CLI 路径或内容变化须用户单独重新授权。旧授权记录缺少公开能力缓存时从 catalog 获取；服务端公开 revision 缺失按 0。catalog 返回空/错误设备/旧epoch或倒退revision时禁止更新，提示先核对原设备或接口支持；不能用 register/resume 代替读取。尚未确认的旧请求与新CLI结果不同时停止，保留原请求，不隐式换请求。

## 接口依据

只读核对 `/Volumes/备份/KAKIAIGC/docs/kaki-tools-local-cli-capabilities-20261007.md` 与 `server/src/routes/local-cli.ts`（publicDevice、catalog、executor、capabilities），未访问真实服务器。

- GET `/api/local-cli/catalog`：`{device: {id,epoch,models,revision,profile,...}|null}`。实际 activeDevice 要求 presence 与未暂停，因此本候选不能读取暂停设备；检测会要求用户单独连接，不自动 resume。
- POST `/api/local-cli/devices/capabilities`：严格 `{expectedRevision,profile:"resolution-five",models}`；按 ID 排序去重，1–7 型号；携带原会话、X-Workspace-Id、原私有设备头。secret 仅由既有程序存储 opaque 使用，不进入文档/日志。
- 响应是公开 device；验证原 id/epoch、模型集合、profile 和 expectedRevision 或 expectedRevision+1；拒绝后退版本。单次原请求持久化到原0600授权文件，不触碰journal。
- CAS冲突409只重新读取/重新确认；原样幂等重试由服务端协议保障。错误归属403、失效epoch等错误不能触发自动关联。
- 新型号保留既有 text/image/frames/multimodal 四命令明确型号交集；旧CLI原基础集合与 multiframe 检查兼容。任务执行器、签名/token/submitId及会员/账务不修改。

## 隔离验证

`KAKI_TEST_SCOPE=capabilities bash scripts/test-macos-native.sh` 编译全部源码/测试，执行型号与原连接恢复测试及能力更新mock。mock使用临时目录、合成会话和私有设备，覆盖严格payload、旧revision、型号增删、原设备头、丢响应/重启原样重试、409重读不自动覆盖、跨设备/epoch/版本拒绝、CLI替换拒绝写、迟到响应失效、暂停偏好保留、0600与journal保留。

正式签名应用构建必须沿用仓库固定签名身份。缺少身份时脚本停止，不能自动换签名；单独优化Swift编译只能作为编译证据，不能当作已签名可发布包。

未验真实CLI/账号/设备更新、真实Studio部署版本、生产Redis/CAS、UI现场交互和真实生成；需后续单独授权。候选提交后须父对话独立安全审查通过再普通push，不能merge main。

实际候选验证：能力/型号/原连接定向62项断言通过；最终源码 arm64 优化编译通过（可执行编译产物，不是签名安装包）。最新远端原样基线全量测试同样在 ShortcutRecorderTests.swift:64 的菜单键事件断言失败；初版候选全量也在此处失败。扩大组合定向时既有 ClassicFiveModesTests 的 CLI 升级fixture抛出 active，未把该组合当作通过证据。固定签名构建因仓库当前身份不可用停止，未更换签名。
