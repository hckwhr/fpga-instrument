# V3 ESP32-S3 BLE / UART bridge

本目录是 stage48 的独立 BLE 转发固件，使用 ESP-IDF 5.4.4 / NimBLE。目标是直接贴装的 ESP32-S3-WROOM-1-N16R8；不是 FPGA 位流，不用于现有 V2，也不是小智语音完整固件。

2026-10-15 已按实际 [V3 引脚适配](../../docs/hardware/V3实际引脚与程序适配_20261015.md) 更新源码。下文 stage48 编译记录对应旧引脚，不能用于本次实物；新版验证见 stage51 记录。尚未烧录、未做无线实测。

2026-10-23：共用桥接源码已选择 **115200**，必须与 stage64 FPGA 配对使用；旧 stage51 二进制仍为 9600。本轮实际构建的是复用本目录的小智 `fpga-bread-s3` 固件，不是重新发布 stage51 独立桥接固件。构建、测试与交付状态见 [stage64 报告](../../docs/串口115200与播放优化_stage64_20261023.md)。

## 接口合同

| 接口 | 本固件配置 |
|---|---|
| UART | UART1，115200 baud，8N1，无 RTS/CTS（旧二进制仍为 9600） |
| S3 TX | GPIO17 / 模组10脚 → FPGA A20 / J13-15，TX2 |
| S3 RX | GPIO18 / 模组11脚 ← FPGA A21 / J13-17，RX2 |
| 功放静音 | GPIO39 / 模组32脚置低，经 R51 接 SD_MODE，LOW 关闭功放 |
| 下载/日志 | 原生 USB Serial/JTAG，保留 GPIO19/20；UART1 不输出日志 |
| BLE 名称 | `行者无疆`（2026-10-20 起） |
| 服务 UUID | `6e400001-b5a3-f393-e0a9-e50e24dcca9e` |
| 写特征 UUID | `6e400002-b5a3-f393-e0a9-e50e24dcca9e`，Write With Response |
| 通知 UUID | `6e400003-b5a3-f393-e0a9-e50e24dcca9e`，Notify |

这些 UUID 与网页 `BleTransport` 默认值一致；网页优先使用 With Response，本固件有意不声明 Without Response。必须先订阅 Notify，再写命令。只允许一个 BLE 连接，尚未加入配对/绑定或应用授权，属于受控联调固件，不能宣称接入认证已完成。

UART 为 3.3V 逻辑、共地。不能把本表套到 V2。FPGA stage51 使用 A20/A21，V3 的 A15 是 ADC 时钟。保留 USB GPIO19/20，不启用麦克风、语音播放或 Wi-Fi；桥接只用内部 RAM，暂不初始化 N16R8 的 PSRAM。旧 GPIO18 静音定义已删除，避免与实际 RX 冲突。

## 转发行为

- NimBLE host 的 GATT/GAP 回调与 10 ms callout 串行访问同一状态，不另开会竞争连接状态的 UART 工作任务。UART 驱动 ISR 只使用 SDK 队列。
- BLE 分片收齐 LF 后才把完整行入 UART 队列；UART 应答也收齐 LF 后才发通知。保留原始 ASCII/CRLF 和 CRC 字节，不生成、篡改或代答 `ACK2`、`ERR2`、`OK`。
- 每行最多 256 字节（含 LF），每方向最多 4 条完整行和 1 条在收行。允许可打印 ASCII 和行尾 CRLF；空行透传。行组装从首字节起最多 2 秒。
- UART TX 环为 1024 字节；上条发送完才提交下一条（最大 256 字节）。每次 callout 最多读 256 字节和处理 32 个 UART 事件，避免在 BLE host 阻塞等待串口线时长。
- UART RX 环为 8192 字节；读取受完整行队列空闲槽限制，队满暂停读取。每轮最多发 16 个通知，临时拥塞保留原偏移重试；固定 4896 字节 SCOPE1 快照可暂存，仍不保证无限流量或无限 BLE 停顿。
- 通知按实际 ATT MTU−3 分片。临时内存/拥塞错误保留当前片重试；连续 2 秒无进展断开。成功入 BLE 栈不等于手机应用已收到，SONG2 的编号、CRC 和主机重试仍负责应用确认。
- 半行超时、非法字符、超长、队列溢出、UART 帧/奇偶/溢出错误或通知失败，清空桥接缓存并断开；不丢弃部分字节后继续假装成功。错误只写 USB 日志，不污染 FPGA 应答流。
- 断线丢弃尚未提交 UART 驱动的完整命令和所有半行/待通知数据。已经提交驱动的**整行会继续发完**；该命令可能已执行，不能撤销，也不自动重发或补发 STOP。主机应显示结果未知，实体停止键仍可用。
- 断线后持续读取并丢弃 UART 应答，TX 完成且 UART 静默至少 3 秒才重新广播。启动时也等待此静默窗口。此举隔离常规尾包，**不是无限延迟应答的证明**：若 FPGA 音频域停钟后很久才恢复，旧短命令无会话编号，必须先恢复/复位 FPGA 再联调。SONG2 则仍由主机按 sid/seq 检查应答归属。
- 不自动擦除 NVS 来修复初始化错误，不访问 FPGA Flash，不自动播放已上传曲谱。

## 软件测试

Windows 本机有 Visual Studio 2022 C 工具、CMake、Node、Python 时，从工程根目录执行：

```powershell
python firmware/esp32s3-bridge/tests/run.py
```

`test_bridge.c` 编译的是生产 `bridge_core.c`，覆盖所有请求拆分点、粘包、FIFO 环绕、双向队列溢出、256 字节边界、全部非法字节、订阅门控、断线双向清理、两方向半包超时、32 位时间回绕，以及多个 MTU 下通知失败重取的字节一致性。

`protocol-roundtrip.mjs` 使用现有网页编码器、明确标注为测试模型的 FPGA 接收器、编译后的 C 转发核心：15 个分片/MTU 组合、1,065 次请求/应答往返，包含 512 字容量传输、PLAY 重试去重及 STOP。另复用 stage47 已验收 RTL bench 的 12 条原始请求/期望应答，包含 BUSY 拒绝。它们不等于无线实测或本批重新运行 RTL。

这些测试不执行 NimBLE 控制器、UART 外设或 FreeRTOS 实际调度；SDK 适配层已编译，通知拥塞、UART 错误中断、重连隔离和实际吞吐仍需 V3 实板故障注入。

## 构建

当前 V3 对应 stage51：从工程根目录运行 `./firmware/esp32s3-bridge/build_v3_stage51.ps1`，使用独立目录 `E:/Gowin/workspace/esp32s3_bridge_stage51_20261015`。实际固件构建成功，应用大小 `0x76910`；源码哈希、构建日志、应用及 bootloader/分区表见 [stage51 S3 证据](../../artifacts/v3_hardware_stage51_20261015/esp32s3/)。本次未烧录。下文 stage48 构建和二进制为历史记录。

在已激活的 ESP-IDF 5.4.4 PowerShell 中，把本目录的 `CMakeLists.txt`、`sdkconfig.defaults`、`main/` 复制到独立 ASCII 构建目录，然后执行：

```powershell
idf.py set-target esp32s3
idf.py build
```

本机执行目录为 `E:/Gowin/workspace/esp32s3_bridge_stage48_20261014`，使用 `-B build_verified`。最初 `C:/Espressif/tools/xtensa-esp-elf/esp-14.2.0_20260121` 缺失 `libstdc++.a`，首次配置失败记录保留；实际成功构建在该进程 PATH 前加入 `E:/Arduino/data/packages/esp32/tools/esp-x32/2601/bin`。两套编译器版本均为 `crosstool-NG esp-14.2.0_20260121 / GCC 14.2.0`，后者 S3 库完整。未改全局环境、未复制库去修补工具链。

```powershell
$env:Path = 'E:/Arduino/data/packages/esp32/tools/esp-x32/2601/bin;' + $env:Path
& 'C:/Espressif/tools/python/v5.4.4/venv/Scripts/python.exe' 'D:/espidf5.44/v5.4.4/esp-idf/tools/idf.py' -B build_verified build
```

应用、bootloader、partition table、ELF、sdkconfig、构建日志和 SHA256 归档见 [stage48 证据](../../artifacts/esp32s3_bridge_stage48_20261014/)。应用不是可直接写地址 0 的合并镜像；未来实板烧录须核对目标、最终硬件与 `flasher_args.json` 的三段地址。

## V3 到板验收

先确认 V3 生产原理图与上述 GPIO 一致，安装本固件后通过 USB 日志确认启动与名称。先接 UART 测试端验证 `HELLO\n` 不会被 S3 自行应答，再接已验收 V3 FPGA 位流，依次测真实 HELLO、CAPS、曲谱上传、CRC/ACK、播放、停止及 RGB LCD 状态。至少覆盖：每个 BLE 分片处断线、发送中断线、未订阅写入、手机后台/恢复、弱连接、错误波特率、串口噪声、连续重连和满容量曲谱。语音/Wi-Fi 共存另开一批验证。
