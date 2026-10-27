# 行者无疆 · FPGA 多维交互数字乐器

比赛项目统一交付仓库，包含高云 FPGA 工程、FPGAvedio 电脑上位机、Android App 源码、ESP32-S3 BLE/小智固件及验证资料。比赛系统提交本仓库一个链接即可。

当前交付快照更新于 **2026-10-27**，FPGA 已完成 Flash 写入、校验及重新加载。显示使用底板 HDMI，输出 **800×600 @56.25 Hz**；音频通过 PT8211 输出。最新硬件效果及部分复位约束仍待复核，详细边界见 [当前验证记录](artifacts/current/validation.md)。

## 目录导航

| 目录 | 内容 |
| --- | --- |
| [fpga/current](fpga/current/README.md) | 当前 FPGA 源码、工程、PLL、引脚与时序约束、仿真 |
| [artifacts/current](artifacts/current/validation.md) | 当前位流、网表、资源/时序/引脚报告、回归及烧录日志 |
| [host/mineradio](docs/HOST.md) | FPGAvedio 双模式桌面播放器、BLE 工作台、Android 源码 |
| host/instrument-web | 共用转谱、曲谱库、可靠上传与可视化 |
| firmware/xiaozhi-v3 | 小智派生固件，当前套件板型 fpga-bread-s3 |
| firmware/esp32s3-bridge | BLE/UART 转发核心与独立桥接工程 |
| [docs](docs/RELEASE.md) | 构建、接线、使用与交付说明 |
| tests | 历史黄金向量和固定参考源码 |
| tools | 构建入口、文件校验、Gowin MCP 与技能快照 |

历史版本和原始日志保留在对应目录，当前入口统一使用 current；旧开发编号不作为产品版本名。

## 功能

- 12 路压力键、摇杆和旋钮；32 复音及 8 路物理琴弦；键位模式、力度表情、音色和效果器。旧四声部 DDS、32 路加法合成及 72 单元并发自检未启用。
- HDMI 面板、RGB 演奏指引、波形、频谱与 XY 余辉。板端 XY 为同一音频信号的延迟采样相图，不是独立左右声道测量；HDMI 不携带音频。
- MIDI/普通音频导入、本地转谱、和弦与延音整理、力度及低音平衡、参考试听、曲谱库、可靠上传和板端独立播放。
- SONG2 分块上传、CRC 与 ACK；容量 4096 事件，起音/释放分别占事件，通常最多 2048 个完整音符，以设备能力和曲谱校验为准。
- BLE 名称“行者无疆”为主连接，USB 手动备用；小智经 Wi-Fi 云服务调用已实现的 FPGA 命令。USB/热点恢复固件候选已有编译记录，尚缺对应实机验收。

## 当前构建与烧录

| 项目 | 原始报告结果 |
| --- | --- |
| 显示 | 800×600 @56.25 Hz；36 MHz 像素 / 180 MHz 串化；800×480 面板居中 |
| 资源 | Logic 71856；LUT 57320；ALU 14536；Register 32589 |
| 物理资源 | CLS 47527/69120（69%）；BSRAM 202/340；DSP 125.5/298；SSRAM 0 |
| 时序 | setup +0.515 ns；hold +0.193 ns；建立/保持违例 0/0 |
| 异步时序 | 最差 recovery +10.423 ns；removal +0.339 ns |
| 已有仿真记录 | 完整回归 143 项 PASS；官方器件模型 3 项 PASS |
| 烧录 | 2026-10-27 Flash 写入校验成功，随后 Reprogram 成功 |

[位流](artifacts/current/pnr/project.fs) SHA256：
`24631a3a373a1e4461c94279a7aa30eb0821b1bcde191fde770256643fc13923`

本次为已构建版本的整理同步，没有重新运行 FPGA 构建或烧录。正时序报告不能替代约束有效性审核：串化时钟改为连续运行后，保留的复位多周期例外仍需重新论证；约束脚本末尾同路径复制错误也保留在记录中。

## 使用入口

1. [硬件接线与固件配对](docs/HARDWARE.md)
2. [构建与测试](docs/BUILD.md)
3. [上位机演示流程](docs/HOST.md)
4. [当前版本说明](docs/RELEASE.md)

## 已知边界

音频转谱是识别音符后由 FPGA 音色重奏，不是传输 MP3 原声；复杂配器仍可能漏音或误识别，超容量需选段或删减。曲谱保存在 RAM，断电丢失。参考试听是近似模拟，不是 DAC 采集。板端回传可视化为有限快照，不保证连续音频流。Android 保留源码与历史编译记录，本次没有新 APK 或手机真机 BLE 验收。

小智当前支持连接检查、内置演示、停止及状态/结果查询，不支持任意歌名点歌。最新 FPGA 实机画面、音频和灯带效果仍需记录；此前版本的用户反馈不代替当前版本验收。

## 来源与维护

保留 Mineradio GPL-3.0-only、小智 MIT 及第三方声明，见 [THIRD_PARTY.md](THIRD_PARTY.md)。仓库不收录账号凭据、Wi-Fi 密码、设备 NVS、激活身份、签名私钥或工具依赖缓存。文件来源及 SHA256 见 SOURCE_MANIFEST.json，整理规则见 [PACKAGING.md](docs/PACKAGING.md)。

仓库保持私密。比赛评委需要获授权访问，私密链接本身不保证可读；未经确认不调整公开状态。后续优化继续提交同一仓库，见 [维护约定](CONTRIBUTING.md)。
