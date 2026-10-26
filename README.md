# 行者无疆 · FPGA 多维交互数字乐器

本仓库是比赛项目的统一源码入口，包含高云 FPGA 工程、FPGAvedio 电脑上位机、Android App 源码、ESP32-S3 BLE/小智固件和验收资料。提交比赛系统时使用**本仓库这一个链接**即可。

当前 FPGA 快照为 **stage68 / HDMI 800×600 @56.25 Hz / UART 115200**，2026-10-26 09:08 完成构建，09:31 完成 Flash 校验及重载。stage67 已有用户确认画面正常、声音正常及灯带跟随的记录；stage68 后补压力曲线、XY 余辉轨迹和内置歌曲灯带修正，新增效果仍需实物复测。原 stage65 LCD 稳定基线完整保留。见 [stage68 状态与证据边界](artifacts/stage68/validation.md)。

2026-10-24 新增配套软件候选：**BLE 主用、USB 手动备用**，默认仍扫描“行者无疆”。桌面应用已更新，配套 ESP32-S3 固件已编译但未烧录、未实测。FPGA stage65 和 UART 115200 不变；USB 需 S3 原生接口及本次固件，不能仅更新电脑软件。见 [连接优化与复测步骤](docs/BLE主用_USB备用与热点恢复_20261024.md)。

## 目录导航

| 目录 | 内容 | 入口 |
| --- | --- | --- |
| `fpga/stage68/` | 当前 HDMI FPGA RTL、工程、PLL、31 引脚、4 时钟、143 项仿真 | [当前工程说明](fpga/stage68/README.md) |
| `fpga/stage65/` | 保留的 LCD 稳定基线，45 引脚、138 项仿真 | [历史验收](artifacts/stage65/verification.json) |
| `fpga/stage64/` | 保留的上一版 115200 基线，136 项仿真 | [历史验收](artifacts/stage64/verification.json) |
| `host/mineradio/` | FPGAvedio 桌面双模式播放器、BLE 工作台、Android 源码 | [上位机说明](docs/HOST.md) |
| `host/instrument-web/` | 共用转谱、曲谱库、可靠上传、可视化和测试 | [构建与测试](docs/BUILD.md#上位机) |
| `firmware/xiaozhi-v3/` | 小智 v1.9.4 派生固件，当前板型 `fpga-bread-s3` | [硬件接线](docs/HARDWARE.md) |
| `firmware/esp32s3-bridge/` | 共用 BLE/UART 转发核心、独立桥接固件及原生主机测试 | [固件说明](docs/BUILD.md#esp32) |
| `artifacts/stage68/` | 当前位流、实施网表、时序/资源/引脚报告、回归及烧录日志 | [版本记录](artifacts/stage68/validation.md) |
| `artifacts/stage67/` | HDMI 首次出画面的历史验收及用户反馈记录 | [上板记录](artifacts/stage67/validation.md) |
| `artifacts/stage65/` | LCD 基线位流及历史验收证据 | [版本验收](docs/RELEASE.md) |
| `artifacts/stage64/` | 上版 FPGA 证据、配套 ESP 工厂镜像及后补烧录记录 | [版本配对](docs/RELEASE.md) |
| `tests/` | 必要的历史 RTL 黄金向量与 stage59b 参考源码，非当前烧录版本 | [参考范围](tests/README.md) |
| `docs/history/` | 原始开发记录与硬件说明；旧参数不作为本版默认值 | [stage64 原始记录](docs/history/串口115200与播放优化_stage64_20261023.md) |

## 当前功能

- 12 路压力键、摇杆与旋钮输入；32 复音引擎及 8 路物理琴弦；同音色/钢琴键位模式、力度与表情、音色及效果器。旧四声部 DDS、32 路加法合成和 72 单元并发自检未在当前 V3 配置启用，不能宣称本版同时启用 72 个发声单元。
- HDMI/灯带反馈、波形和频谱；XY 面板使用同一音频信号的延迟采样相图与余辉，不冒充独立左右声道测量。HDMI 只传视频，音频仍走 PT8211。上位机本地可视化与 FPGA 数据回传分开，回传是有限快照，不是连续实时音频流。
- MIDI/普通音频导入、本地音频转音符、旋律整理、试听、曲谱库、SONG2 分块上传/CRC/ACK、板端独立播放。当前板端容量 4096 事件，起音和释放分别占事件，通常至多 2048 个完整音符，实际须通过板端能力和曲谱校验。
- 纯音乐准备采用“选段 → 一键生成”，默认“和弦与延音”保留和弦、重复起音、长音及原节奏，LCD 单声部引导与实际复音播放分轨；保留旧单声部兼容模式。容量删减明确报告，原生 MIDI 48–83 音高不整体移动。提供识别音符试听和 stage65 FPGA 演奏参考；板端上传歌曲采用衰减保持包络和干声，手动演奏配置保留。详见 [复音转谱优化](docs/纯音乐复音转谱优化_20261024.md)。
- BLE 名称“行者无疆”为主连接；USB 手动备用，连接后锁定模式，不自动切换或重放命令。小智通过 Wi-Fi 云服务调用已实现的 FPGA 命令，BLE、USB 与语音命令实行链路互斥。

新转谱已改为按音频能量估算相对力度，复音模式默认移调低音 60% 力度；重新转谱、生成、上传后生效，固件不变。说明与验证范围见 [力度与低音平衡优化](docs/伴奏力度与低音平衡优化_20261024.md)。

## 快速开始

1. 阅读 [硬件与版本配对](docs/HARDWARE.md)，核对 FPGA 型号、ESP 存储配置及接线。
2. 按 [构建说明](docs/BUILD.md) 安装工具，构建共用前端和 FPGAvedio，或查看现有 [验收记录](docs/RELEASE.md)。
3. 连接 BLE“行者无疆”，识别设备并读取上传能力；导入曲谱、整理和试听、上传，取得提交确认后再播放。详见 [演示流程](docs/HOST.md)。
4. 源码修改后运行对应回归；涉及 RTL 时先完整仿真，再综合/P&R/时序及引脚审计。新位流验收后才允许烧录。

## stage68 当前构建摘要

| 项目 | 实际记录 |
| --- | --- |
| 显示 | VESA DMT 800×600 @56.25 Hz；36 MHz 像素 / 180 MHz 串化；内部面板 800×480 居中 |
| 资源 | Logic 70932；LUT 56394；ALU 14538；Register 32585；CLS 47176/69120（69%）；BSRAM 202；DSP 125.5 |
| 时序 | setup +0.756 ns；hold +0.186 ns；建立/保持违例 0/0；recovery +9.742 ns；removal +0.264 ns |
| 验证 | 原始日志 143 个回归 PASS，官方器件模型 3 项 PASS；P&R 与位流生成完成 |
| 烧录 | 2026-10-26 操作 69 写入校验成功，操作 1 Reload 成功 |
| 验证边界 | stage68 新效果待实物复测；本次为现有版本归档，不宣称重跑全部验收或新增引脚审计 |

位流 SHA256：`08f87785ab0fb051da06b3e77d01d8553de814ad8955cc803a78b5a629825019`。
注意原构建目录仍名为 `v3_hdmi_stage67_20261025`，本仓库按日志版本分为 `fpga/stage68` 和 `artifacts/stage68`。
压缩约束脚本末尾同路径复制报错、日志中残留的“600 行面板”描述均如实保留并在版本记录中说明。

## stage65 历史验收摘要（LCD）

| 项目 | 实际记录 |
| --- | --- |
| FPGA | GW5AST-LV138PG484AC1/I0；Gowin V1.9.12.03；place3 / route2 |
| 资源 | Logic 69852；CLS 46665/69120（68%）；SSRAM 0；BSRAM 200/340；DSP 113.5/298 |
| 布线与时序 | 未布通 0；setup **+0.043 ns**；hold **+0.185 ns**；建立/保持违例 **0/0** |
| 约束 | 3 时钟、8 条 multicycle 生效；45 引脚审计 clean |
| 回归 | RTL 138/138（原 136 项保留）；共用上位机后补优化 124/124（上一轮 119 项保留）；浏览器、App、打包桌面冒烟通过 |
| 实物边界 | stage65 Flash 写入校验及重新加载成功；参考试听是近似模拟，实际音质仍需上板 A/B 测试 |

位流 SHA256：`bf6a795a1bc01d2494a76fa5c882b6a4a9d7af6bba27ea28616621df2b48a8d2`。证据见 [verification.json](artifacts/stage65/verification.json)、[最终 P&R](artifacts/stage65/pnr/pnr_final.json) 和 [时序报告](artifacts/stage65/pnr/v3_hardware_top_tr_content.html)。setup 达到 +0.03 ns 门槛但余量较小。存在一条 `PR1014` 通用时钟布线警告，已记录，不声称零警告。

stage65 后补烧录记录及原始日志见 [programming/README.md](artifacts/stage65/programming/README.md)；构建时验收 JSON 保持原貌。stage64 同日较早的烧录记录仍保留在对应归档中。烧录成功不等于歌曲端到端或主观音质验收。

## 已知限制

MP3 转谱是提取音符后由 FPGA 音色重奏，不是 MP3 原声传输；默认整理保留模型识别出的和弦与延音，但不保证还原原曲配器、鼓点和音色，复杂纯音乐仍可能漏音或误识别，超容量须删减或选段。本轮新转谱尚待板端实物 A/B 试听。歌曲仅存于板端 RAM，断电丢失。Android 有源码及历史编译记录，但本轮未生成新 APK，也未完成手机真机 BLE 验收。语音当前支持连接检查、内置演示、停止、状态/结果查询，不能按任意歌名点歌或控制未实现的音色命令。

## 来源、隐私与后续维护

开发辅助工具见 [Gowin MCP 0.5](tools/gowin-mcp/README.md) 和
[Gowin 技能快照](tools/skills/gowin-fpga/SKILL.md)。本轮选择性吸收外部
skills/rules 的验证方法，补齐构建证据与残缺时序报告判定；35 项工具回归通过，
生产 RTL 与既有位流未变。采用和排除内容见 [改进记录](docs/技能与MCP优化_20261024.md)。

这是多个组件的统一仓库，并非把所有上游作品改为团队原创。保留 Mineradio 的 GPL-3.0-only、小智的 MIT 及第三方声明，见 [THIRD_PARTY.md](THIRD_PARTY.md)。不收录账号 cookie/token、Wi-Fi 密码、设备 NVS、激活身份、签名私钥、依赖缓存或工具安装包。

仓库保持私有。私有不等于评委自动有权限：提交前须按主办方要求给评审账号访问权限，或在你明确同意后调整可见性，不能仅凭一个私有链接保证评审可读取。后续优化继续在同一仓库提交和推送，不推送 ESP32/Mineradio 上游、不改写历史；维护约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。
