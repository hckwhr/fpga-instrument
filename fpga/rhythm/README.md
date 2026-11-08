# 十二键跟练与双屏演奏

2026-11-08 验收：161 项 RTL 回归及 3 项官方器件模型通过；setup +2.010 ns、
hold +0.185 ns，建立/保持违例为零，恢复/移除报告无负余量，54 引脚和 5 时钟
审计通过。位流已生成，尚未烧录。完整记录见本机 `artifacts/v5_rhythm_dual_20261107/validation.md`。

目标板为 Tang Mega 138K / GW5AST-138C（SOM 30354、Dock 31005），外接 V5
十二键压力键盘。入口为 `v3_hdmi_top.gprj`，使用原 800×480 RGB LCD 与底板 HDMI。
这是独立开发候选，已有板上程序及其本机基线目录未被覆盖。

## 显示与演奏

LCD 常驻设置页，保留实体设置键和原菜单控制方式。音色、力度、弯音、颤音、
效果器等参数通过独立的稳定总线握手送入 LCD，在帧边界更新。

HDMI 维持已使用的 800×600 输出及中心 800×480 画布，显示十二个固定琴键、
波形、蓝色频谱和紫色李萨如。背景为白色，波形前景颜色保持原样，不显示设置参数。
实体键的位置不随跟练谱的自定义音高变化。两屏独立扫描，显示更新不阻塞音频。

上位机通过原 PERF1 协议下发目标键与提示编号。RGB 给出对应键位，正确压力键
在 FPGA 本地触发发声；错按静音，支持和弦，同一键的新提示需松开后重按。
曲目播放停止后，跟练启用请求明确交接曲目/试听所有权，再检查接收条件，
避免界面开始按钮被遗留的播放状态持续阻塞。非法请求和按键忙不触发交接。

保留 32 个独立声部和 8 路物理弦。音频采样、压力流水线及 ESP32 的透明串口
桥接协议不变；不要求仅为本次双屏改动重新烧录 ESP32。

## 重建与验证

复制本目录至独立 ASCII 路径，使用 Gowin V1.9.12.03 和 ModelSim：

```powershell
pwsh -File sim/run_dynamic_regression.ps1 -Jobs 12
pwsh -File sim/run_hdmi_phy.ps1
```

完整回归为 161 项，原 159 项不删减，新增双屏模块和双屏整机各一项。
整机测试从 UART、ADC 引脚施加激励，解码 RGB 和 PT8211 输出，并检查
实际 SONG2 上传、播放、停止之后的跟练切换。另有三项官方 HDMI 器件模型测试。

先综合，再对本次综合网表生成时序约束：

```powershell
pwsh -File scripts/prepare_performance_constraints.ps1 -Netlist <构建目录>/impl/gwsynthesis/v3_hdmi_top.vg
```

共同使能证明、端点压缩等价和负向测试全部通过后，使用 place3/route2 完整
布局布线。生成的 SDC 对应特定网表，修改 RTL 后必须重新生成，不能用名字
匹配替代实际使能证明。目标审计为 54 个物理 I/O、5 个时钟，四类时序违例为零，
setup ≥ +0.03 ns、hold ≥ 0。位流生成不等于已烧录。

协议细节见 [RHYTHM_PROTOCOL.md](RHYTHM_PROTOCOL.md)，本轮改动边界见
[DUAL_DISPLAY_CHANGE.md](DUAL_DISPLAY_CHANGE.md)。本机报告归档于
`artifacts/v5_rhythm_dual_20261107/`，实际验收结果以该候选报告为准。
