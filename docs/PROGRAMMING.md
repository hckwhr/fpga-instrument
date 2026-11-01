# FPGA 下载配置

适用板卡为 Tang Mega 138K（SOM30354 + Dock31005），器件 GW5AST-138C，JTAG ID `0x0001081B`。固定使用 Gowin Programmer V1.9.12.03、USB Debugger A、0.5 MHz。当前源码入口见 [构建方法](BUILD.md)。

只读扫描确认唯一目标后，在本次 ASCII 构建目录执行。下面的位流文件名是占位符，须替换为本次实际产物；不要使用其他器件或旧工程的文件。

```text
programmer_cli.exe --device GW5AST-138C --chain_index 0 --cable-index 4 --frequency 0.5MHz --operation_index 69 --spiaddr 0x000000 --fsFile <本次位流.fs>
```

仅当日志明确包含 `Program and Verify flash successfully.` 且无错误，才执行重新加载：

```text
programmer_cli.exe --device GW5AST-138C --chain_index 0 --cable-index 4 --frequency 0.5MHz --operation_index 1
```

日志中的下载器必须为 USB Debugger A，器件必须为 GW5AST-138C / `0x0001081B`。不能仅凭退出码 0 或 `Finished.` 判断成功。此工具版本的 `cable-index 4` 表示下载器类型，不是插拔后变化的枚举序号。

固定配置失败时保留日志，检查连接、供电、驱动和占用；不自动改频率、Flash 地址或下载器参数。多目标或型号不符时停止。本源码包不包含自动执行的烧录步骤。
