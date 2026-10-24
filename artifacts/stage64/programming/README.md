# stage64 FPGA 烧录记录

- 日期：2026-10-24
- 工具：Gowin Programmer V1.9.12.03
- 目标：Tang Mega 138K / GW5AST-138C，JTAG ID `0x0001081B`
- 下载器：USB Debugger A，0.5 MHz
- 位流：`E:/Gowin/workspace/v3_uart115200_stage64_20261023/impl/pnr/v3_hardware_top.fs`
- SHA256：`1B4F6ECC1CF45449713798A20A52289174F56EF2D0D549EFB22094CF771F63ED`

先执行只读扫描：发现 1 个器件，ID 为 `0x0001081B`。随后按固定配置执行操作 69（外部 Flash 擦除、写入并校验），Programmer 控制台明确返回 `Program and Verify flash successfully.`，耗时 185.65 秒，退出码 0。其后执行操作 1（Reprogram），日志见 `stage64_reload.log`，目标正确并显示 `Finished.`，耗时 0.19 秒。

操作 69 的完整逐进度控制台输出由本次执行会话返回；未落盘为原始日志文件。此处仅记录从实际输出核实的结果，不伪称是原始日志。Reload 步骤的完整命令输出已保存。

烧录及重新加载完成；板上 UART 115200 通信、ESP 配对、歌曲上传与播放效果尚待实物功能测试。
