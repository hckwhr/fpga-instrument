# 硬件、接线与版本配对

FPGA：Tang Mega 138K，SOM30354 + Dock31005，器件 GW5AST-138C / GW5AST-LV138PG484AC1/I0。当前 HDMI 工程使用 31 个顶层引脚，位置与 I/O 属性见 [v3_hdmi.cst](../fpga/current/constraints/v3_hdmi.cst)。

HDMI 接 Dock 板载接口：D0 J14/H14、D1 J15/H15、D2 K17/J17、CLK G15/G16，发送使能 K14。当前输出 800×600 @56.25 Hz，屏幕需独立供电；音频仍走 PT8211，HDMI 不携带音频。界面面板为 800×480，在输出画面中居中。

## ESP32 到 FPGA

| ESP32-S3 | FPGA |
| --- | --- |
| GPIO17 TX | A20 RX（Dock J13-15） |
| GPIO18 RX | A21 TX（Dock J13-17） |
| GND | FPGA GND（例如 J13-12） |

业务串口 UART1，115200、8N1、3.3 V。两板各自供电，只接 TX/RX/GND，不互接 5 V、不接 RS232 电平。A15 是 ADC 时钟，不是 UART。不能让两块 ESP 的 TX 同时驱动 FPGA A20。

## 两种 ESP 固件不可混为一谈

- `xiaozhi-v3` 名称为历史名称，当前套件配置面向 **fpga-bread-s3 通用套件 N16R8**，不是 V3 PCB。INMP441 WS/SCK/SD=4/5/6；MAX98357 DIN/BCLK/LRC=7/15/16；SSD1306 SDA/SCL=41/42，默认 128×64。参见 [板型详细说明](../firmware/xiaozhi-v3/main/boards/fpga-bread-s3/README.md)。
- `esp32s3-bridge` 是独立 V3 BLE 桥接工程，共用 bridge_core/voice_core；其板级引脚须参照 [pinmap.json](../firmware/esp32s3-bridge/pinmap.json)。该工程使用独立板型配置，小智通用套件与 V3 PCB 应分别选用对应固件。

BLE 名称为“行者无疆”，NUS 服务 `6e400001-b5a3-f393-e0a9-e50e24dcca9e`，写入 0002、通知 0003。Wi-Fi 使用小智配网/激活，不在仓库写入热点密码。设备身份和激活属于设备/账号，不由电脑浏览器自动迁移。

BLE 上位机连接时语音串口命令拒绝接管；断开后至少等 3 秒再语音控制。语音事务期间暂停广播，避免向上传或采样流插入命令。

## 固件与外设配置

FPGA 使用 Gowin Programmer V1.9.12.03，目标器件 GW5AST-138C；沿用工程固定的 USB Debugger A、0.5MHz 下载设置。工具操作与接线应匹配当前器件。

ESP 应用地址由分区表决定，地址表见 [配套镜像布局](../artifacts/stage64/esp32/flash_args)。其中 xiaozhi.bin 是偏移 0x100000 的应用镜像，不是从地址 0 开始的合并镜像。配置文件不包含设备 NVS 身份，更换硬件时应保留设备配置并匹配 Flash/PSRAM 容量。
