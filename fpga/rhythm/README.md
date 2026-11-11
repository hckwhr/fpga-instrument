# 十二键跟练与 HDMI 单屏显示

本版本恢复 HDMI 单屏，163 项回归及 3 项官方模型通过，setup +0.556 ns、
hold +0.187 ns，31 引脚/4 时钟审计通过。位流已生成，尚未烧录。
修改源码不改变已烧录程序。2026-11-11 已按用户要求将最新工程归档到 GitHub；本次整理不烧录。

目标板为 Tang Mega 138K / GW5AST-138C（SOM 30354、Dock 31005），外接 V5
十二键压力键盘。入口为 `v3_hdmi_top.gprj`，仅使用底板 HDMI，不连接 LCD。
这是当前归档的最新源码，已有板上程序及其本机基线目录未被覆盖。

## 显示与演奏

实体设置键在 HDMI 上打开原设置页，退出后恢复演奏页面。音色、力度、弯音、
颤音、效果器等参数通过原稳定总线握手送入 HDMI，在帧边界更新。

HDMI 维持已使用的 800×600 输出，恢复原浅色仪表盘、琴键、波形、频谱和
李萨如。生产顶层没有 LCD 物理端口，LCD PLL、设置显示、时序和双屏专用
演奏渲染器不进入生产文件列表。历史双屏源码仅保留用于模块回归。

上位机通过原 PERF1 协议下发目标键与提示编号。RGB 给出对应键位，正确压力键
在 FPGA 本地触发发声；错按静音，支持和弦，同一键的新提示需松开后重按。
曲目播放停止后，跟练启用请求明确交接曲目/试听所有权，再检查接收条件，
避免界面开始按钮被遗留的播放状态持续阻塞。非法请求和按键忙不触发交接。

保留 32 个独立声部和 8 路物理弦。音频采样、压力流水线及 ESP32 的透明串口
桥接协议不变；不要求仅为取消 LCD 重新烧录 ESP32。

## 重建与验证

复制本目录至独立 ASCII 路径，使用 Gowin V1.9.12.03 和 ModelSim：

```powershell
pwsh -File sim/run_dynamic_regression.ps1 -Jobs 12
pwsh -File sim/run_hdmi_phy.ps1
```

完整回归为 163 项，原 162 项全部保留。`tb_hdmi_menu_refresh` 从实体
菜单引脚向前和向后逐次切换五种乐器，要求每次按键两帧内更新，帧内不撕裂，
退出后压力键仍能通过解码的 PT8211 音频验证发声。历史双屏两项仍作模块检查。
新增 `tb_panel_decimal_exact` 穷举数字转换，并与优化前冻结渲染器核对字形；
详见 `DECIMAL_CHANGE.md`，不以预计资源减少代替实际报告。
整机测试从 UART、ADC 引脚施加激励，解码 RGB 和 PT8211 输出，并检查
实际 SONG2 上传、播放、停止之后的跟练切换。另有三项官方 HDMI 器件模型测试。

先综合，再对本次综合网表生成时序约束：

```powershell
pwsh -File scripts/prepare_performance_constraints.ps1 -Netlist <构建目录>/impl/gwsynthesis/v3_hdmi_top.vg
```

共同使能证明、端点压缩等价和负向测试全部通过后，使用 place3/route2 完整
布局布线。生成的 SDC 对应特定网表，修改 RTL 后必须重新生成，不能用名字
匹配替代实际使能证明。目标审计为 31 个物理 I/O、4 个时钟，四类时序违例为零，
setup ≥ +0.03 ns、hold ≥ 0。位流生成不等于已烧录。

协议细节见 [RHYTHM_PROTOCOL.md](RHYTHM_PROTOCOL.md)，本轮改动边界见
[HDMI_ONLY_CHANGE.md](HDMI_ONLY_CHANGE.md)。本机报告归档于
`artifacts/v5_rhythm_hdmi_digits_20261110/`，实际验收结果以本候选报告为准。
