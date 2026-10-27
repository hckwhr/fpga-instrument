# 演奏扩展工程

本目录在既有 HDMI 乐器架构上增加 12 个实体键的自定义音高，以及真实混音 PCM 的录音回传。独立于 `fpga/current`，保留原有 32 复音、8 路物理弦、HDMI、PT8211 与曲谱播放路径。

入口：`v3_hdmi_top.gprj`。板卡为 Tang Mega 138K，器件 GW5AST-LV138PG484AC1/I0；31 引脚与四时钟配置沿用基线，UART 为 115200、8N1。

[功能与构建说明](../../docs/PERFORMANCE.md)
