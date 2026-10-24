# stage65 FPGA 永久烧录记录

2026-10-24，按用户“先烧录 FPGA”指令执行。Programmer V1.9.12.03，USB Debugger A，0.5 MHz；只读扫描确认唯一目标 GW5AST-138C / `0x0001081B`。

烧录文件：`E:/Gowin/workspace/v3_instrumental_stage65_20261024/impl/pnr/v3_hardware_top.fs`。烧录前与归档位流逐一计算 SHA256，均为 `bf6a795a1bc01d2494a76fa5c882b6a4a9d7af6bba27ea28616621df2b48a8d2`。

固定公共参数：`--device GW5AST-138C --chain_index 0 --cable-index 4 --frequency 0.5MHz`。

1. `--scan`：1 device(s) found，目标及下载器匹配，见 `stage65_scan.log`。
2. `--operation_index 69 --spiaddr 0x000000 --fsFile <上述位流>`：日志明确包含 `Program and Verify flash successfully.`，185.34 秒，退出码 0，无错误，见 `stage65_flash_op69.log`。
3. 仅在写入校验成功后执行 `--operation_index 1`：Reprogram / Finished，0.19 秒，退出码 0，无错误，见 `stage65_reload.log`。

完整工具路径：`E:/Gowin/Gowin_V1.9.12.03_x64/Programmer/bin/programmer_cli.exe`。工作目录为上述 ASCII 构建目录。

本次确认 Flash 写入、校验与重新加载成功；尚未观测实际音频、压力键及 BLE 歌曲上传播放效果。ESP32 本轮未烧录，沿用 UART 115200 配套固件。上级 `verification.json` 保留构建验收时的历史快照，烧录状态以本后补记录为准。
