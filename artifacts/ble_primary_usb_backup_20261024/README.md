# BLE 主用 / USB 手动备用候选

2026-10-24。默认连接为 BLE「行者无疆」，USB 仅为手动备用；断开并完成清理后切换，不自动重放上传或播放命令。桌面 FPGAvedio 已更新，重启生效。FPGA stage65、115200 UART、引脚及时钟未改动。

## 验证记录

- `frontend-tests.txt`：130/130，原 124 项保留，零失败/跳过。
- `desktop-link-tests.txt`：9/9，含明确授权、取消及过期 USB 选择保护。
- `bridge-tests.txt`：3/3 C 核心；15 种分片/MTU、1065 次 SONG2 往返及 12 条原 RTL 黄金交换。
- `desktop-smoke.json`：实际打包程序，BLE 默认、Serial API、模式切换、窗口按钮、转谱及可视化通过。BLE/USB 设备使用模拟，未打开实物端口。
- `desktop-interface-delivery.json`：桌面 33 文件更新并核对成功，个人数据未改动。
- `esp-build.txt`：ESP-IDF 5.4.4 编译成功，有上游 LV_USE_OS 和旧触摸 API 警告。

真实 MP3/模型浏览器与 App 流程也已通过；没有新 APK，没有测量实物吞吐、无线干扰恢复或热点重连。候选固件尚未烧录，编译通过不代表上板通过。

## 固件归档

板型为独立 ESP32-S3 `fpga-bread-s3` / N16R8，不能当作 V3 PCB 镜像使用。`firmware-sha256.json` 记录各文件哈希。应用 `xiaozhi.bin` 为 2800256 字节，SHA256：

`77ea0c2b2aad7d2a57cb250f019cbe5e4e61da4e27e620cb89f8fc8e1366a37c`

配套 `firmware/flash_args` 的地址表如下，仅记录本次构建，不是自动烧录指令：

| 地址 | 文件 |
| --- | --- |
| 0x0 | bootloader/bootloader.bin |
| 0x8000 | partition_table/partition-table.bin |
| 0xd000 | ota_data_initial.bin |
| 0x10000 | srmodels/srmodels.bin |
| 0x100000 | xiaozhi.bin |

Flash 配置为 dio / 80m / 16MB。未归档 NVS、设备身份或密码；已验证 stage64 镜像保持原样。旧板更新前须核对实际分区及 OTA 活动槽，不能直接假定仅写应用或整套镜像均可安全更新。

USB 备用须接 S3 原生 USB Serial/JTAG（GPIO19/20），不是普通 USB 转 UART 调试口。使用及复测见 [连接说明](../../docs/BLE主用_USB备用与热点恢复_20261024.md)。
