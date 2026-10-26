# stage68 HDMI 当前源码快照

目标 Tang Mega 138K SOM30354 + Dock31005，GW5AST-LV138PG484AC1/I0，Gowin V1.9.12.03。
入口为 `v3_hdmi_top.gprj`，顶层 `v3_hdmi_top`，place3 / route2。

本目录逐字节整理自实际构建目录 `E:/Gowin/workspace/v3_hdmi_stage67_20261025`。
该目录在 2026-10-26 生成 `pnr_stage68.log` 并再次烧录，因此仓库标为 stage68。
未改动生产 RTL、PLL、CST、SDC 或测试断言；文件来源和 SHA256 见根 `SOURCE_MANIFEST.json`。

- HDMI 为 800×600 @56.25 Hz，内部 800×480 面板垂直居中，上下各 60 行。
- 单显示 PLL：36 MHz 像素、180 MHz 串化；加上系统和音频共 4 个约束时钟。
- 音频走 PT8211，采样协议和 UART 115200 保留；LCD 不作为本版输出。
- 压力曲线提升轻按可听力度；XY 图形使用同音频延迟 32 个样本形成相图、自动幅度及余辉。
- 内置歌曲灯带改为跟随有效音高集合，不再仅以上传曲目试听标志判断。

## 验证与构建

当前位流、原始报告、143 项回归及 3 项官方模型日志、烧录日志见
[stage68 记录](../../artifacts/stage68/validation.md)。新增体验尚无本版实物反馈归档。

请在 ASCII 独立目录运行完整回归与官方模型测试：

```powershell
pwsh -File sim/run_dynamic_regression.ps1 -Jobs 12
pwsh -File sim/run_hdmi_phy.ps1
```

`scripts/syn_only.tcl` / `pnr_only.tcl` 接收工程路径参数。
改 RTL 后仍必须重新做 CE 审计与 SDC 压缩、完整 P&R、四类时序及引脚审计。
这里保留的 `prepare_*`、`compact_queries.py`、`sync_and_test.ps1` 和归档脚本含原工作站及旧版本硬编码路径，
不是可直接跨机器运行的入口；必须先核对路径，禁止把新构建写入旧验收目录。
通用入口与限制见 [构建说明](../../docs/BUILD.md#fpga)。本次 GitHub 同步没有重新构建或烧录。

不要照抄历史 README 或回归提示里的“铺满 600 行”：当前 RTL 明确仍为 480 行面板。
