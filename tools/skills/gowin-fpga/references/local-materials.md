# Local Gowin Materials

## Current Inventory

`E:\Gowin` contains about 12,800 files (about 5.05 GB): two Gowin EDA installs,
four Gowin course projects, and one incomplete workspace project. Related local
notes live in `C:\Users\hck\Desktop\高云`. Prefer `Gowin_V1.9.12.03_x64`; keep
`Gowin_V1.9.11.03_Education_x64` only for version comparison.

### Maintained notes

| Need | Source |
|---|---|
| Tang Mega 138K versions, clocks, pins, audio, schematics | `C:\Users\hck\Desktop\高云\00_Tang_Mega_138K硬件资料索引.md` |
| Gowin EDA beginner flow and screenshots | `C:\Users\hck\Desktop\高云\高云入门开发 基本操作.md` |
| GAO screenshot pointers | `C:\Users\hck\Desktop\高云\GAO config.md` |
| 2026 FPGA contest platforms and topics | `C:\Users\hck\Desktop\高云\全国大学生嵌入式芯片与系统设计竞赛'2026FPGA赛道选题指南-高云半导体.pdf` |

The Desktop copy of the hardware index has broken relative links, but the raw
bundle is available under `E:\gaowin\硬件资料` (47 files, about 92.6 MB).
It contains the SOM/Dock schematics, PG484A Pinout PDF/XLSX, official CST,
mechanical data, and related manuals. `E:\Gowin\硬件资料` is a different empty
directory; use the lowercase `gaowin` path exactly. Derived text and rendered
pages remain under `C:\Users\hck\Desktop\高云\.tmp_138k_docs` for fast search,
but constraints should cite the raw bundle.

### Installed official manuals

The V1.9.12.03 installation has current raw manuals:

| Question | Manual |
|---|---|
| IDE project flow | `IDE\doc\CN\SUG100-4.4.6_Gowin云源软件用户指南.pdf` |
| Tcl and `gw_sh` commands | `IDE\doc\CN\SUG1220-2.0_Gowin云源软件Tcl命令用户指南.pdf` |
| Synthesis behavior/options | `IDE\doc\CN\SUG550-2.4_GowinSynthesis用户指南.pdf` |
| CST physical constraints | `IDE\doc\CN\SUG935-1.6.1_Gowin设计物理约束用户指南.pdf` |
| SDC timing constraints | `IDE\doc\CN\SUG940-2.0.4_Gowin设计时序约束用户指南.pdf` |
| HDL coding guidance | `IDE\doc\CN\SUG949-2.2_Gowin HDL编码风格用户指南.pdf` |
| Programming UI/CLI | `Programmer\doc\CN\SUG502-2.5.1_Gowin Programmer用户指南.pdf` |
| Arora V 138K configuration | `Programmer\doc\CN\UG704-1.0.7_Arora Ⅴ 138K FPGA产品编程配置手册.pdf` |

All paths in this table are relative to
`E:\Gowin\Gowin_V1.9.12.03_x64`.

### Course archives

Under `E:\Gowin\micu\嵌赛（FPGA）\高云`:

1. `key_ctrl_led.zip`: keys and LEDs.
2. `1 key_ctrl_led_seg.zip`: divider and 74HC595 seven-segment display.
3. `2 uart_ctrl_led_seg.zip`: UART RX/TX and command processing.
4. `3 uart_ctrl_da.zip`: PLL, ROM waveforms, UART, and dual 8-bit DA output.

They include source, CST/SDC, historical reports, and bitstreams for the course
board. Reuse architecture only after recording board/device and interface
differences. Never treat archived implementation output as a current build.

### Installed examples

V1.9.12.03 includes examples for CAN, CPU, FFT, FIFO, game, JESD204B, LED,
NPU, and VGA under `IDE\data\examples`. Use them to confirm tool syntax and IP
integration, not as board pin evidence.
