# 小智 S3 通用接线 / FPGA 测试板

本板型是小智官方 v1.9.4 的独立配置 `fpga-bread-s3`，使用
`bread-compact-wifi` 的分离 I²S 接线。它不是 V3 PCB 配置，也不是所有商家
标注“通用接线”的确认凭据。烧录前核对模块 Flash/PSRAM 容量与下面的线序。
默认构建面向 ESP32-S3 N16R8（16 MB Flash、8 MB octal PSRAM）。

| 功能 | S3 GPIO / 接法 |
|---|---|
| INMP441 WS / SCK / SD | 4 / 5 / 6；L/R 接 GND，VDD=3.3 V |
| MAX98357 DIN / BCLK / LRC | 7 / 15 / 16；SD 不受 V3 GPIO39 静音逻辑控制 |
| 可选 SSD1306 SDA / SCL | 41 / 42；地址 0x3C，默认 128×64，32 行屏修改板型配置 |
| BOOT 对话键 | GPIO0，沿用原板型行为 |
| 可选按住说话 / 音量加 / 减 | 47 / 40 / 39，低有效 |
| 板载灯 | GPIO48，沿用原板型 |
| FPGA 串口 TX | GPIO17 → FPGA A20（J13-15） |
| FPGA 串口 RX | GPIO18 ← FPGA A21（J13-17） |
| 地 | S3 GND ↔ FPGA GND，例如 J13-12 |

UART1，当前源码为 115200、8N1、3.3 V 电平，须配对 stage64 FPGA；旧固件为 9600。
两端各自供电，只接 TX/RX/GND，不互接 5V。FPGA 与 ESP32 必须同时更新波特率。
这是 FPGA A20/A21 业务串口，不是接 FPGA 的下载器串口。
不得同时让另一块 ESP32 的 TX 驱动 FPGA A20。GPIO18 不再配置原版 LampController。
OLED 缺失时探测后使用 NoDisplay，不阻止语音。未支持 SH1106 的自动识别。

## 已实现控制入口

| 小智设备 MCP 工具 | 实际发送 | 说明 |
|---|---|---|
| self.fpga.ping | PING LF | 返回 PONG 才确认连接 |
| self.fpga.play_demo(song_id) | PLAY,0 LF / PLAY,1 LF | 0 小星星，1 欢乐颂；收到带相同编号的确认才表示选曲执行 |
| self.fpga.stop | STOP LF | 停止曲目；stage62 的 remote_song_stop 同时进入上传播放器 local_stop |
| self.fpga.status | STATUS LF | 内置播放器状态，不包含 SONG2 上传播放器状态 |
| self.fpga.result | 无串口发送 | 按 ticket 读上一条命令的 queued/waiting/confirmed/failed |

工具先返回排队票号。模型须查询 result，不能把排队当作执行成功。
等待 UART 在 NimBLE 定时任务完成，不阻塞小智主事件循环或音频任务。
匹配的 FPGA 应答才标记 confirmed；拒绝、超时、错误帧和其他命令的 ACK 不会报成功。
超时不自动重发，返回“执行未知”。票号不是 FPGA 的端到端事务号。

测试说法：“检查 FPGA 是否连接”“让 FPGA 播放内置演示曲”“停止 FPGA 播放”。
小智普通扬声器音量工具只调小智喇叭，不等于 FPGA 的 PT8211 音量。
选曲需要配套 v5_playability_20261030 或后续 FPGA 固件；旧板端返回 ERR,COMMAND 时不会退回通用 PLAY 冒充选曲成功。
尚不提供音色/弯音/FPGA音量语音指令。当前播放歌曲切换会重新起播；上传歌曲运行时先停止再选择内置曲目。

## Wi-Fi 与 BLE

Wi-Fi 沿用小智热点配网和云端激活、MQTT/WebSocket 音频/MCP 通信；无需在源码写密码。
离线唤醒不代表离线语义识别。完整语音控制需要正常联网和支持设备 MCP 的小智服务。

BLE 继续用 `行者无疆`、原 NUS UUID，复用 `firmware/esp32s3-bridge` 完整行桥接。
启动时不会重新初始化 NVS，也不会把 GPIO39 拉低干扰音量键。
当前采用明确的串口独占策略：**电脑 BLE 连接期间拒绝语音串口命令**。
先断开上位机 BLE，等至少 3 秒再语音控制。语音事务期间暂停广播；事务后排空尾包再恢复。
这样不向正在上传的 SONG2 数据或 SCOPE1 快照中插入短命令，也不把语音 ACK 发给电脑。
Wi-Fi/BLE 射频共存仍需真实板卡测试，不能由编译或主机测试推定。

如 FPGA 停钟很久后恢复，短协议没有事务编号，3 秒排空不能证明旧 ACK 永不迟到；
应恢复/复位 FPGA 再测试，不应靠无限重试控制。

## 源码与构建

- 适配底本：78/xiaozhi-esp32 v1.9.4，提交 `3ced7709c65a39494f5684e99111854a5bcbd8c7`。
- 选择理由：组件要求 IDF >=5.4.0，可使用本机已验证的 5.4.4。
- `../xiaozhi-esp32` 独立保存官方新版本供对照，其 HEAD 需要 IDF >=6.0.1，未用于此固件。
- 原有板型和引脚未改；此分支移除了本板不使用且注册库已下架的 image_player/emote_gfx 依赖，
  不保证原 EchoEar/ESP-HI 等其他板型可由此分支构建。
- 工程根运行 `./firmware/xiaozhi-v3/build_fpga.ps1`，使用独立 ASCII 构建目录。
- 没有自动烧录、自动擦除 NVS、修改 FPGA 位流或修改电脑上位机。

最终编译与测试结果见项目 `docs/小智语音控制FPGA_20261022.md`，不要把本文接线方案当作实物验收。
