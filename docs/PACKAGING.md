# 提交源码包

仓库和提交包使用相同目录结构，入口为根目录 README。FPGA、上位机与 ESP32-S3 固件集中在一个仓库，保留组件之间的相对路径即可构建。

| 目录 | 内容 |
| --- | --- |
| fpga/playability | 当前 FPGA 工程、RTL、约束、ROM 与仿真 |
| host/mineradio | FPGAvedio Windows 播放器及 Android 应用 |
| host/instrument-web | 共用转谱、上传、曲谱库、录音及可视化 |
| firmware/xiaozhi-v3 | 小智语音与 ESP32-S3 套件适配 |
| firmware/esp32s3-bridge | BLE/USB/UART 桥接及小智所需共用核心 |
| docs/submission | 技术报告 Word、PDF、Markdown 及插图 |
| artifacts/playability | 当前功能测试和实施结果 |
| tests / tools | 固定测试输入与构建入口 |

生产 FPGA 只保留一套工程。测试中的冻结参考及兼容配置用于验证协议、时序契约和行为一致性，不能当作当前烧录入口。

源码包从 Git 提交导出，不包含 `.git`、旧生产工程、依赖缓存、工具安装包、设备身份或签名私钥。报告中的资源与时序数据来自已实施结果，源码注释整理不产生新的 FPGA 实施结果。安装依赖和构建方法见 [BUILD.md](BUILD.md)。

下载仓库或解压源码包后，建议使用 ASCII 工作路径。上位机两个目录及固件两个目录分别保持相邻；不要单独搬走共用组件。第三方许可证及来源见 [THIRD_PARTY.md](../THIRD_PARTY.md)。
