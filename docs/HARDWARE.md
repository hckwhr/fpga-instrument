# 硬件、接线与版本配对

FPGA：Tang Mega 138K，SOM30354 + Dock31005，器件 GW5AST-138C / GW5AST-LV138PG484AC1/I0。当前 HDMI 工程 的 31 引脚来源是 [v3_hdmi.cst](../fpga/current/constraints/v3_hdmi.cst)；历史 LCD 版本为 45 引脚。接线前核对板卡及原理图，本次整理没有修改生产引脚、时钟或 CDC。

HDMI 接 Dock 板载接口：D0 J14/H14、D1 J15/H15、D2 K17/J17、CLK G15/G16，发送使能 K14。当前输出 800×600 @56.25 Hz，屏幕需独立供电；音频仍走 PT8211，HDMI 不携带音频。早期 HDMI 版本已有实机出画面记录；最新串化时钟修正后的效果待复测。

## ESP32 到 FPGA

| ESP32-S3 | FPGA |
| --- | --- |
| GPIO17 TX | A20 RX（Dock J13-15） |
| GPIO18 RX | A21 TX（Dock J13-17） |
| GND | FPGA GND（例如 J13-12） |

业务串口 UART1，115200、8N1、3.3 V。两板各自供电，只接 TX/RX/GND，不互接 5 V、不接 RS232 电平。A15 是 ADC 时钟，不是 UART。不能让两块 ESP 的 TX 同时驱动 FPGA A20。

## 两种 ESP 固件不可混为一谈

- `xiaozhi-v3` 名称为历史名称，当前验收镜像面向 **fpga-bread-s3 通用套件 N16R8**，不是 V3 PCB。INMP441 WS/SCK/SD=4/5/6；MAX98357 DIN/BCLK/LRC=7/15/16；SSD1306 SDA/SCL=41/42，默认 128×64。参见 [板型详细说明](../firmware/xiaozhi-v3/main/boards/fpga-bread-s3/README.md)。
- `esp32s3-bridge` 是独立 V3 BLE 桥接工程，共用 bridge_core/voice_core；其板级引脚须参照 [pinmap.json](../firmware/esp32s3-bridge/pinmap.json)。历史验收未单独重建/实测该独立镜像，不能把小智通用套件镜像当成 V3 PCB 镜像。

BLE 名称为“行者无疆”，NUS 服务 `6e400001-b5a3-f393-e0a9-e50e24dcca9e`，写入 0002、通知 0003。Wi-Fi 使用小智配网/激活，不在仓库写入热点密码。设备身份和激活属于设备/账号，不由电脑浏览器自动迁移。

BLE 上位机连接时语音串口命令拒绝接管；断开后至少等 3 秒再语音控制。语音事务期间暂停广播，避免向上传或采样流插入命令。

## 烧录边界

当前版本已在 2026-10-27 完成 Flash 写入校验及重载，详见 [当前记录](../artifacts/current/validation.md)。本次上传不会重烧硬件。

历史 LCD 版本已于 2026-10-24 完成 Flash 写入校验及重新加载，见 [烧录记录](../artifacts/stage65/programming/README.md)；实际音质待试听。FPGA 永久下载遵循 [固定配置](history/固定烧录配置.md)：Programmer V1.9.12.03，GW5AST-138C，chain_index 0、cable-index 4、0.5MHz；操作 69、Flash 0x000000、写入校验后 Reprogram。实际烧录前须扫描唯一目标并检查器件 ID，不能只看退出码。

ESP 镜像地址见 [历史配套地址表](../artifacts/stage64/esp32/flash_args)，其中 `xiaozhi.bin` 是偏移 0x100000 的应用，不是地址 0 的合并镜像；未包含 NVS 或设备身份备份。更换硬件/分区前须保留用户设备配置并核对实际 Flash/PSRAM。
