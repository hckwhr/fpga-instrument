# stage65 验收与产物

验收日期 2026-10-24。实际依据为 [verification.json](../artifacts/stage65/verification.json) 和原始报告，详细改动见 [纯音乐演奏优化](纯音乐演奏优化_stage65_20261024.md)。

- RTL 全回归 138/138，原 136 项保留。新增歌曲包络/力度/ID 释放与 UART 上传到独立 PT8211 解码专项；扩展效果器退出恢复测试。手动演奏与关闭新功能的参考比较 6000 个采样逐位一致。
- 上位机 108/108，完整构建、真实 MP3/模型浏览器验证、App 与打包桌面冒烟通过。App 的 BLE/FPGA 为模拟设备，本轮未进行实物 BLE 测试。
- FPGA P&R：Logic 69852、LUT 55393、ALU 14459、Register 32341、CLS 46665/69120（报告取整 68%）、BSRAM 200/340、SSRAM 0、DSP 113.5/298、I/O 45；未布通 0。
- STA：setup +0.043 ns，hold +0.185 ns，违例 0/0；3 时钟和 4 对 setup/hold multicycle 生效，45 引脚审计 clean。setup 达到 +0.03 ns 门槛但余量较小。保留 PR1014 通用时钟布线警告。
- 位流 [v3_hardware_top.fs](../artifacts/stage65/pnr/v3_hardware_top.fs)，SHA256 `bf6a795a1bc01d2494a76fa5c882b6a4a9d7af6bba27ea28616621df2b48a8d2`。
- 桌面共用界面已更新，重启 FPGAvedio 生效；未修改个人数据。本轮没有生成新 APK。

**2026-10-24 后补：stage65 已永久写入 Flash、校验并重新加载**，见 [原始烧录日志及记录](../artifacts/stage65/programming/README.md)。构建时的 verification.json 保持历史原貌。参考试听近似模拟钢琴波形、包络和高频补偿，不是 DAC 采集。构建时上位机为单主旋律整理；其后更新见下一节，不回写历史验收结果。

## 2026-10-24 上位机复音转谱后补

默认“和弦与延音”保留和弦、重复起音和完整长音，LCD 引导与实际复音分轨；原生音区不再整体抬高，超范围音区统一移动八度。旧单声部模式保留且等价测试通过。容量、密度和力度检查继续生效，删减明确显示。

- 共用前端完整构建 119/119、0 失败、0 跳过，原 108 项保留、新增 11 项。真实 MP3/模型浏览器、App 和实际打包桌面测试通过；BLE/FPGA 为模拟设备，本轮未做新曲谱实物 A/B。
- 本机同一原曲前 30 秒 222 个识别音符全保留，444 事件、最大占用 8 声部；整首保留 2048 音符、4096 事件，有 402 个音符因容量省略，不宣称无损转谱。
- 桌面界面已更新并核对 27 个文件哈希，需要重启及重新生成/上传；未生成新 APK。FPGA stage65、ESP stage64 均未改动，无需烧录，前述资源、时序和位流 SHA256 不变。

详细依据及复测步骤见 [优化记录](纯音乐复音转谱优化_20261024.md)，离线统计和桌面/App 证据见 [host-polyphony-20261024](../artifacts/host-polyphony-20261024/)。仓库不收录原曲、用户录音或该曲生成的音符存档。

## 配套 ESP32 与历史基线

stage65 维持 SONG2、4096 事件与 UART 115200；本轮没有修改 ESP 固件，沿用 [stage64 镜像](../artifacts/stage64/)。小智 `xiaozhi.bin` SHA256 为 `d1ba5ab56ca9f7824955bf95ee23a50ca8a0e476ca43bc4a1b2e7042e7e157f9`，ESP-IDF 5.4.4 / fpga-bread-s3 / N16R8。地址以镜像配套 flash_args 为准，不含设备 NVS 身份。

stage64 原始验收是 2026-10-23 的构建记录，保留在 [verification.json](../artifacts/stage64/verification.json)，不回写历史结果。2026-10-24 已完成 stage64 FPGA Flash 写入校验及重新加载，见后补 [烧录记录](../artifacts/stage64/programming/README.md)。操作 69 控制台结果有会话记录，原始逐进度日志未落盘；Reload 原始日志已保留。此记录不声称歌曲端到端实测通过。

230400 仅有 UART 仿真与有限桥接模型验证，不是正式速率；115200 模型中的快照转发耗时不是 BLE 实测速率。报告中的旧工作站绝对路径是证据的一部分，不是新机器构建入口。旧 `pnr_running.json` 只是历史快照，最终状态以各版 `pnr/pnr_final.json` 为准。
