# 节奏跟练与压力流水版 FPGA

这是与当前上位机实体 12 键跟练协议配套的独立源码快照。目标为
Tang Mega 138K / GW5AST-138C（SOM 30354、Dock 31005），外接 V5 压力键盘。
入口为 `v3_hdmi_top.gprj`。保留 `../playability` 历史生产入口，不覆盖已烧录基线。
本快照于 2026-11-07 完成仿真、综合和布局布线，尚未烧录验证。

## 本版行为

- 上位机通过 PERF1 op6 下发 12 位目标掩码与 cue ID，op7 查询命中并续租。
- FPGA 驱动对应 RGB 指引；正确实体压力键在 FPGA 本地触发声部，错按不响。
- 同音下一次 cue 必须先松开，支持和弦、停止与连接超时保护。
- 保留 32 声部、8 路物理弦、现有乐器音色、上传播放及 HDMI 显示。
- 压力减零点、增益与力度曲线分级运算，门限、迟滞、曲线结果不变。
  按键、力度、摇杆组成同一帧后通过原 CDC，增加四个 sys_clk 周期（80 ns）。

协议及流水边沿契约分别见 [RHYTHM_PROTOCOL.md](RHYTHM_PROTOCOL.md) 和
[TIMING_CHANGE.md](TIMING_CHANGE.md)。ESP32 沿用透明行桥，不需要为这次
压力时序优化重新烧录。

## 已完成验证

| 项目 | 实测结果 |
|---|---|
| 完整 RTL 回归 | 159 通过 / 0 失败（原 158 项 + 1 项压力流水等价） |
| 官方 HDMI 模型 | PLL、串化、停钟复位 3 项通过 |
| 压力冻结参考 | 12,182 完整帧、132,096 曲线组合一致 |
| 生产按键到 DAC 延迟 | 144 场景，最慢 1.557 ms |
| 节奏引脚测试 | UART → C17 RGB → 实际 ADC → 物理弦/32声部 → PT8211 PCM |
| Setup / hold | +2.596 ns / +0.195 ns |
| 建立 / 保持违例端点 | 0 / 0 |
| Recovery / Removal | 最差 +9.773 ns / +0.250 ns，报告负余量均 0 |
| 引脚 / 时钟 | 31 引脚含差分配对与 I/O 属性；4 时钟通过 |
| Logic / LUT / ALU | 72703 / 57389 / 15314 |
| Register / CLS | 34688 / 48585（总 CLS 69120） |
| BSRAM / SSRAM / DSP | 205 / 0 / 126 |

Gowin V1.9.12.03，place3/route2，布局布线约 18 分 12 秒，`.pr`、时序报告、
位流完整生成。成功日志未单列未布通条数，不把缺失字段填成测得的 0。
此前节奏候选 setup 为 0.000 ns、hold 为 +0.193 ns；本轮只改压力输入生产 RTL。
其他路径的余量变化也受到重新布局影响，不能全部归因于压力流水。

SDC SHA256：`43ce5a51b05d34d447225323c9c9d78cc08d80e16f3a31899041ee10b2bb017a`。
位流 SHA256：`b4e6645b6eb480e6294159a6824008045209a4afb661d11034b77fefff326531`。
构建产物在本机 `artifacts/v5_rhythm_timing_20261107/` 归档，不作为源码提交。

## 重建

复制本目录至独立 ASCII 路径，安装本机对应 Gowin 与 ModelSim 工具链：

```powershell
pwsh -File sim/run_dynamic_regression.ps1 -Jobs 12
pwsh -File sim/run_hdmi_phy.ps1
```

综合 `v3_hdmi_top.gprj` 后，使用**本次**网表更新共同 CE 证明与压缩约束：

```powershell
pwsh -File scripts/prepare_performance_constraints.ps1 -Netlist <构建目录>/impl/gwsynthesis/v3_hdmi_top.vg
```

证明及负向测试全过后以 place3/route2 完整 P&R，再验收四类时序、引脚与时钟。
已提交的 SDC 只对应记录中的网表，不能在修改 RTL 后直接沿用旧集合。
压力流水处于全速 sys_clk 域，没有增加多周期或 false-path 例外。

仿真和 STA 不替代上板观察；本次本地提交不表示已经烧录或推送 GitHub。
