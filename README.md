# 行者无疆 · FPGA 多维交互数字乐器

本仓库是比赛项目的统一源码入口，包含高云 FPGA 工程、FPGAvedio 电脑上位机、Android App 源码、ESP32-S3 BLE/小智固件和验收资料。提交比赛系统时使用**本仓库这一个链接**即可。

当前发布候选为 **stage64 / UART 115200**。FPGA 与 ESP32 必须配对更新，不能将 9600 的旧固件与本版混用。本版已完成软件测试、FPGA 综合、布局布线、时序及引脚审计；**尚未烧录并实测 stage64 的端到端行为**，不要将构建通过当作实物验收。

## 目录导航

| 目录 | 内容 | 入口 |
| --- | --- | --- |
| `fpga/stage64/` | 当前 FPGA RTL、Gowin 工程、PLL、45 引脚约束、SDC、136 项仿真 | [FPGA 构建说明](docs/BUILD.md#fpga) |
| `host/mineradio/` | FPGAvedio 桌面双模式播放器、BLE 工作台、Android 源码 | [上位机说明](docs/HOST.md) |
| `host/instrument-web/` | 共用转谱、曲谱库、可靠上传、可视化和测试 | [构建与测试](docs/BUILD.md#上位机) |
| `firmware/xiaozhi-v3/` | 小智 v1.9.4 派生固件，当前板型 `fpga-bread-s3` | [硬件接线](docs/HARDWARE.md) |
| `firmware/esp32s3-bridge/` | 共用 BLE/UART 转发核心、独立桥接固件及原生主机测试 | [固件说明](docs/BUILD.md#esp32) |
| `artifacts/stage64/` | FPGA 位流、ESP 工厂镜像、时序/资源/引脚报告、回归证据 | [版本验收](docs/RELEASE.md) |
| `tests/` | 必要的历史 RTL 黄金向量与 stage59b 参考源码，非当前烧录版本 | [参考范围](tests/README.md) |
| `docs/history/` | 原始开发记录与硬件说明；旧参数不作为本版默认值 | [stage64 原始记录](docs/history/串口115200与播放优化_stage64_20261023.md) |

## 当前功能

- 12 路压力键、摇杆与旋钮输入；32 复音引擎及 8 路物理琴弦；同音色/钢琴键位模式、力度与表情、音色及效果器。旧四声部 DDS、32 路加法合成和 72 单元并发自检未在当前 V3 配置启用，不能宣称本版同时启用 72 个发声单元。
- LCD/灯带反馈，波形、频谱、李萨如图形；上位机本地可视化与 FPGA 数据回传分开显示。FPGA 音频回传是有限快照，不是连续实时音频流。
- MIDI/普通音频导入、本地音频转音符、旋律整理、试听、曲谱库、SONG2 分块上传/CRC/ACK、板端独立播放。当前板端容量 4096 事件，起音和释放分别占事件，通常至多 2048 个完整音符，实际须通过板端能力和曲谱校验。
- BLE 名称“行者无疆”；小智通过 Wi-Fi 云服务调用已实现的 FPGA 命令，BLE 上传与语音命令实行链路互斥。

## 快速开始

1. 阅读 [硬件与版本配对](docs/HARDWARE.md)，核对 FPGA 型号、ESP 存储配置及接线。
2. 按 [构建说明](docs/BUILD.md) 安装工具，构建共用前端和 FPGAvedio，或查看现有 [验收记录](docs/RELEASE.md)。
3. 连接 BLE“行者无疆”，识别设备并读取上传能力；导入曲谱、整理和试听、上传，取得提交确认后再播放。详见 [演示流程](docs/HOST.md)。
4. 源码修改后运行对应回归；涉及 RTL 时先完整仿真，再综合/P&R/时序及引脚审计。新位流验收后才允许烧录。

## stage64 验收摘要

| 项目 | 实际记录 |
| --- | --- |
| FPGA | GW5AST-LV138PG484AC1/I0；Gowin V1.9.12.03；place3 / route2 |
| 资源 | Logic 69909；CLS 46564/69120（68%）；SSRAM 0；BSRAM 200/340；DSP 113.5/298 |
| 布线与时序 | 未布通 0；setup **+0.098 ns**；hold **+0.188 ns**；建立/保持违例 **0/0** |
| 约束 | 3 时钟、8 条 multicycle 生效；45 引脚审计 clean |
| 回归 | RTL 136/136；共用上位机 106/106；桥接/语音主机测试及软件冒烟通过 |
| 实物边界 | stage64 未烧录；BLE/Wi-Fi 共存吞吐和实际音质仍需上板测试 |

位流 SHA256：`1b4f6ecc1cf45449713798a20a52289174f56ef2d0d549efb22094cf771f63ed`。证据见 [verification.json](artifacts/stage64/verification.json)、[最终 P&R](artifacts/stage64/pnr/pnr_final.json) 和 [时序报告](artifacts/stage64/pnr/v3_hardware_top_tr_content.html)。存在一条 `PR1014` 通用时钟布线警告，已记录，不声称零警告。

## 已知限制

MP3 转谱是提取音符后由 FPGA 音色重奏，不是 MP3 原声传输；复杂人声/伴奏不能保证还原，小星星等旋律清晰的曲目更适合演示。歌曲仅存于板端 RAM，断电丢失。Android 有源码及历史编译记录，但不以此声称本版已完成手机真机 BLE 验收。语音当前支持连接检查、内置演示、停止、状态/结果查询，不能按任意歌名点歌或控制未实现的音色命令。

## 来源、隐私与后续维护

这是多个组件的统一仓库，并非把所有上游作品改为团队原创。保留 Mineradio 的 GPL-3.0-only、小智的 MIT 及第三方声明，见 [THIRD_PARTY.md](THIRD_PARTY.md)。不收录账号 cookie/token、Wi-Fi 密码、设备 NVS、激活身份、签名私钥、依赖缓存或工具安装包。

仓库保持私有。私有不等于评委自动有权限：提交前须按主办方要求给评审账号访问权限，或在你明确同意后调整可见性，不能仅凭一个私有链接保证评审可读取。后续优化继续在同一仓库提交和推送，不推送 ESP32/Mineradio 上游、不改写历史；维护约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。
