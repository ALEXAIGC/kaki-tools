# 即梦积分只读刷新客户端候选

余额分支独立于能力 PR #1，基线 `124eb1c135538a45c2973e5541bf711b0a2b5481`。遵守与02/04确认的 v1.1/v1.2：Studio显式打开/刷新创建或复用60秒槽；仅原已连接Tools轮询独立设备端GET。槽没有命令参数，客户端只调用固定 `dreamina user_credit`，20秒超时。没有槽时不查询或上传。不接生成claim、计费账本或数据库任务。

## 网络合同

- GET `/api/local-cli/devices/credit-refresh`，原Studio会话/工作区和私有设备头，返回 `{request:null|{requestId,deviceId,epoch,capabilityRevision,status,requestedAt,expiresAt}}`。
- GET `/api/local-cli/credit-snapshot` 同私有设备认证bootstrap，只有原device/epoch/revision匹配及active设备投影有 `sequenceMeta.lastSequence` 才继续；不fallback浏览器投影。
- POST `/api/local-cli/devices/credit-snapshot` 严格 `{epoch,capabilityRevision,sequence,queriedAt,status,totalCredit?,requestId?}`。网络丢响应保留完全原payload，不改requestId/revision/queriedAt；服务端完成槽不再被poll返回时，从私有reservation恢复原请求上下文，在原60秒内只重传pending、不再查询CLI；409清pending，须Studio下一次明确请求重新查。ack核验原上下文、device/epoch/revision/requestId、snapshotSequence及sequenceMeta.lastSequence精确等于已发送序号。金额未知/错误/过期不显示0。
- 服务端负责同一原子多键CAS复验请求槽仍存在、current/presence/paused/owner/epoch/revision及deadline；金额独立物理TTL，meta不含金额，晚幂等不重建余额、不续TTL、不恢复槽。客户端不以本地校验替代服务器权限。

## 原生端与私有持久化

首次请求确认查询当前本机即梦登录；查询返回user_id仅在内存规范化，用原device.secret HMAC本地比较，身份变化清旧显示后确认采用。原ID、name、vip、raw输出或错误不保存/上传，不新增生成身份权限锚点。不以余额判断会员、限制生成或切渠道重投。

信用查询子进程通过系统sandbox-exec禁止所有文件写，避免官方CLI的内置账户诊断日志落盘；该固定runner不接受其他命令。未登录或CLI需要写登录态刷新时可失败，不自动登录或扩大权限。

credit目录0700，owner/origin/workspace/device/epoch哈希命名的独立记录0600。与原authorization/journal分开，旧连接/暂停/能力写路径不会覆盖序号。每次bootstrap取 max(local reserved,server highwater)+1；安全整数耗尽停止。先写requestId预约和seq，再CLI；fsync文件→rename→fsync目录成功后继续。跨重启同requestId不再query；已有pending可原样重试。取消/失败预留序号空洞可接受，未确认身份不保存原ID。失去context/CLI变化/取消/60秒到期丢弃迟到查询或回执；文件损坏失败关闭，不猜0或重新注册。

原生页面显示最近查询时间并披露外部登录/积分使用可能改变结果；无法保证即时观察外部终端切换账号。过期清除仅本地定时，不触发新查询；旧pending含金额到120秒后清理，保留无金额序号。主动断开停轮询、清余额。取消其他原生操作会重启已连接设备的请求轮询，但不重查已预约request。

首次或换号确认拒绝时本机记录该request已处理、丢弃余额，不重复提示/查询；共享浏览器请求在原60秒自然过期，浏览器可显式取消。确认窗口本身不延长请求deadline，晚确认不发送新余额。

## 隔离验证与边界

使用 `TMPDIR=/tmp KAKI_TEST_SCOPE=credit bash scripts/test-macos-native.sh`，全部源码与测试warnings-as-errors编译，余额mock与原能力/连接回归。mock固定CLI命令/20秒上限、真实0/小数、错误无金额、首次/换号确认、跨重启原payload重试、CLI前预约去重、上下文失效、409、错误ack、私有模式及独立已连接poller完整网络链路。

本轮未执行真实CLI余额查询、未上传余额、未更新真实设备/安装app。签名配置与版本不改；仅优化编译不等于可发布签名安装包。浏览器共享请求/CAS/Redis TTL竞态由02/04独立验证，端到端真实部署、已安装CLI日志隔离、原生确认现场与跨进程崩溃持久性仍未验。候选须独立安全审查后才推送。

最终候选验证：余额模块、完整Tools轮询网络mock链路与原能力/连接回归共264项断言通过；所有源码及测试以warnings-as-errors编译通过。最终arm64优化编译成功，仅为编译核验产物，非已签名安装包。早期迭代修复了辅助日期函数actor隔离；最终源码编译和测试在独占kaki-tools-credit日志中取证。全量原快捷键基线失败与固定签名身份不可用仍沿用能力候选已记录限制。
