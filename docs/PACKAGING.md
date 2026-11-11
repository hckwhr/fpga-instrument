# 源码归档与目录组织

仓库和提交包使用相同目录结构，入口为根目录 README。FPGA、上位机与 ESP32-S3 固件集中在一个仓库，保留组件之间的相对路径即可构建。

| 目录 | 内容 |
| --- | --- |
| fpga/rhythm | 最新 HDMI 单屏工程、RTL、约束、ROM、163 项仿真及验收记录 |
| fpga/playability | 保留的早期已上板基线 |
| host/mineradio | FPGAvedio Windows 播放器及 Android 应用 |
| host/instrument-web | 共用转谱、上传、曲谱库、录音及可视化 |
| firmware/xiaozhi-v3 | 小智语音与 ESP32-S3 套件适配 |
| firmware/esp32s3-bridge | BLE/USB/UART 桥接及小智所需共用核心 |
| docs/submission | 技术报告 Word、PDF、Markdown 及插图 |
| artifacts/playability | 早期基线的功能测试和实施结果 |
| docs/portfolio | 项目展示、简历描述、面试讲解和证据索引 |
| tests / tools | 固定测试输入与构建入口 |

当前归档保留最新 `fpga/rhythm` 与早期 `fpga/playability` 两个明确区分的入口，不删除历史基线。阅读和重建最新版本从 `fpga/rhythm` 开始。测试中的冻结参考及兼容配置用于验证协议、时序契约和行为一致性，不能当作烧录入口。

重新导出源码包时应以明确的 Git 提交为准，不包含 `.git`、依赖缓存、工具安装包、设备身份或签名私钥。过去已经导出的比赛压缩包不会随仓库自动更新。报告中的资源与时序数据来自各自版本的已实施结果，文档整理不产生新的 FPGA 实施结果。安装依赖和构建方法见 [BUILD.md](BUILD.md)。

下载仓库或解压源码包后，建议使用 ASCII 工作路径。上位机两个目录及固件两个目录分别保持相邻；不要单独搬走共用组件。第三方许可证及来源见 [THIRD_PARTY.md](../THIRD_PARTY.md)。
