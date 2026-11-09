# 即梦图片候选 · Mac 测试

本候选为 Frame 图片节点增加本机 text2image / image2image 执行。没有改变安装包版本，也没有发布安装包。Windows 已完成 Studio 定向类型与任务测试；本仓库 Swift 编译和以下原生测试须在 Mac 上执行。

## 本机自动测试（不调用真实 CLI、不消耗即梦额度）

在仓库根目录运行：

```bash
KAKI_TEST_SCOPE=images bash scripts/test-macos-native.sh
```

成功标记为 `IMAGE_TESTS_PASSED`。覆盖图片命令、能力白名单、图片解码、上传中断后重启恢复，以及提交状态不明时不重复生成。

```bash
bash scripts/test-macos-native.sh
```

再构建开发应用：

```bash
bash scripts/run-macos-native.sh
```

构建使用已有签名配置；缺少本机签名证书时按 macos/PACKAGING.md 配置，不绕过签名检查。

## 实机联调前提

Studio 必须包含本次图片 CLI 后端和前端改动。仅更新 Tools 不能令旧版 Studio 支持图片。当前 Studio 改动保留在 Windows 活动工作区，尚未部署，因此暂不能把正式站作为本候选的完整联调环境。

在 Tools 的账号与连接页面重新检测 CLI，连接本人 Studio 账号和目标工作区。只会公布 text2image、image2image 两个 help 都支持的型号。旧 CLI 仍可用视频能力，不会伪报图片支持。

共同支持的图片规格：2K / 4K；每任务一张；最多10张已保存图片引用；比例 1:1、3:4、4:3、16:9、9:16、3:2、2:3、21:9。模型候选为 Seedream 4.0/4.1/4.5/4.6/4.7/5.0/5.0Pro，实际以安装的 CLI help 为准。

## alex 的真实测试

1. 图片节点 → 即梦 CLI，只能选择本机已公布型号。
2. 先测纯文字 2K 一张；再测连接已有图片的图生图，确认结果回到对应节点。
3. 测试正常任务的刷新恢复，确认不会产生第二个提交。
4. 上传中断只恢复原结果，不重新生成；UNKNOWN 待核对状态禁止重发。
5. 官方/特价分类仍来自后台配置，CLI 不经过平台图片 API 报价或积分扣费。

真实生成会使用本人即梦额度，请由 alex 在 Mac 上主动触发。本候选未执行真实付费生成。

重点核对实际 query_result 输出是否符合 `result_json.images` 单项数组，含 `path` 或 `image_url`。若 CLI 版本返回其他结构，保持原 submit_id，不重新生成；提供去掉个人信息与签名 URL 的字段结构以便调整解析。
