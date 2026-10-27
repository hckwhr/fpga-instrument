# 当前构建与烧录证据

## 时间与文件

构建于 2026-10-26 21:47:35 完成。2026-10-27 16:15:16 完成 Flash 写入校验，16:15:30 完成 Reprogram。源码位于 ../../fpga/current；本目录保留工具原始日志及输出，仅归档文件名采用中性名称。

- [实施日志](logs/implementation.log)
- [资源报告](pnr/project.rpt.txt)
- [时序报告](pnr/project_tr_content.html)
- [引脚报告](pnr/project.pin.html)
- [回归日志](logs/regression.log)
- [官方模型测试](logs/phy.log)
- [扫描日志](programming/scan.log)
- [Flash 写入校验](programming/flash_op69.log)
- [重新加载](programming/reload.log)

## 报告实测值

| 指标 | 结果 |
| --- | --- |
| Logic / LUT / ALU | 71856 / 57320 / 14536 |
| Register | 32589 |
| CLS | 47527/69120，报告取整 69% |
| BSRAM / SSRAM | 202/340 / 0 |
| DSP | 125.5/298 |
| I/O | 31 |
| setup / hold | +0.515 ns / +0.193 ns |
| 建立 / 保持违例 | 0 / 0 |
| 最差 recovery / removal | +10.423 ns / +0.339 ns |
| 仿真 | 原始日志 143 项 PASS；官方模型 3 项 PASS |

最终布线及位流生成完成；构建目录有新布局数据库，Git 不收录大体积数据库。实际参数 place3/route2。实施耗时 14 分 27 秒，其中布局 7 分 18 秒、布线 6 分 59 秒。保留 PR1014 通用时钟布线警告，不宣称零警告。

位流 [project.fs](pnr/project.fs)，40,068,191 字节，SHA256：
`24631a3a373a1e4461c94279a7aa30eb0821b1bcde191fde770256643fc13923`

归档 SDC [applied.sdc](applied.sdc) SHA256：
`ca1718cfadc67968aa2c02c9e27f7f495d96495e9f7845ea84199a0fdb5be440`

扫描唯一目标为 GW5AST-138C / 0x0001081B，USB Debugger A，0.5MHz；操作 69 日志明确包含 Program and Verify flash successfully.，随后操作 1 Reprogram 完成。烧录成功不等于显示器兼容性、音质或整机功能验收。

## 尚未闭环的事项

1. FCLK 已改为连续运行，原先基于停钟契约的 OSER RESET→FCLK 多周期例外仍保留 setup/end 4 与 hold/end 3。需要针对连续时钟重新证明实际发射/捕获沿关系；保持启动复位和仿真通过不能单独证明释放后的恢复/移除例外成立。上述 STA 数值是当前约束下的工具结果。
2. [约束准备日志](logs/constraints.log)前部有 CE/集合检查结果，但末尾 Copy-Item 同源同目标报错，不能称整个脚本成功。重新综合等价、最终实施网表和实际 SDC 的对应关系，以及新版引脚/时钟审计仍须明确核对。
3. recovery/removal 在本页报告最差余量，不将它们伪称为工具明确给出的四类独立违例计数。
4. 当前最新版本的实机画面、声音和灯带观察尚未形成记录。此前正常显示版本的反馈不作为本版实测依据。

本次仅同步和整理既有证据，没有重跑 RTL/P&R、改动硬件或追加烧录。
