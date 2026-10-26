# Stage67：800x600@56 HDMI，已烧录并上板确认

状态：2026-10-25 完成全部验收门槛、永久烧录、Reload，**用户已实测确认画面正常、
有声音、灯带跟随**。这是第一个上板出画面的 HDMI 版本。

## 锁定配置

Tang Mega 138K，SOM 30354 + Dock 31005，器件 `GW5AST-LV138PG484AC1/I0`，
Gowin V1.9.12.03。源码 `work/v3_hdmi_stage67_20261025`，构建
`E:/Gowin/workspace/v3_hdmi_stage67_20261025`。
stage65 与 stage66/b/c/d/e 全部保留，未覆盖。

## 根因：1080p30 不被显示器接受

stage66 系列五轮（66/66b/66c/66d/66e）均采用 CEA 1920x1080p30。该模式是
CEA-861 VIC 34，只存在于电视模式表；本发送端是纯 DVI，不发 AVI InfoFrame，
显示器按 DVI 处理，只接受 VESA DMT 模式。用户两台显示器表现为：一台解出
时序后闪一下即拒绝、一台直接弹"不支持"。

重要佐证：官方 `sipeed/TangMega-138K-example` 的 `hdmi_colorbar` 同样是
1080p30（75 MHz，2200x1125），在本板同样无信号。**失败不是因为本实现差于
官方**。官方预编译 `hdmi.fs` 为 Device Version B / AC2-I1，与本板 C 版不符，
按固定烧录规则未写入，改用其源码重编译；另发现官方 `hdmi.cst` 未约束 K14
`hdmi_tx_enable`（Dock31005 的 HDMI +5V 与 TX 端接），该端口会被自动分配，
是官方例程在本 Dock 完全无信号的原因；补上 K14 后仍为 1080p30，依然无信号。

探针验证（`vesa_probe_20261025`、`vesa_probe56_20261025`，均已烧录实测）：
800x600@60 与 800x600@56 两台显示器均正常显示。

## 改动

| | 66e | stage67 |
|---|---|---|
| 模式 | CEA 1920x1080p30 | VESA DMT 800x600@56（1024x625 总周期，56.25 Hz）|
| PLL | 级联两级，VCO 1012.5 + 1113.75 MHz | 单级，VCO 900 MHz |
| 时钟 | 371.25 / 74.25 / 37.125 MHz | 180 / 36 MHz |
| TMDS | 742.5 Mbps/lane | 360 Mbps/lane |
| 面板映射 | 800x480 放大 2 倍居中于 1920x1080 | 1:1 居中于 800x600，垂直偏移 60 |
| 时钟数 | 六 | 四（三条生成时钟约束）|
| 渲染周期 | 26.936 ns | 27.778 ns |

PLL 参数 IDIV=1 / MDIV=18 / ODIV0=5 / ODIV1=25，`MULTI_FAC=18`。
`render_clk` 不再是独立输出，直接等于 `pixel_clk`，渲染域与 TMDS 编码器
合为同一时钟域。删除不再实例化的 `hdmi_reference_pll`；从工程移除 8 个
已禁用的 LCD/触摸条目（此前已 enable=0，不作为资源节省声称）。

同时修正一处会导致灯带时序错乱的问题：`ws2812_tx` 挂在渲染时钟上，参数
原为 `CLOCK_KHZ=37125` / `STARTUP_CYCLES=371250`，改为 36000 / 360000
（仍为 10 ms）。全 RTL 扫描确认这是唯一按时钟频率标定的模块。

保留 66d/66e 成果：共同 CE `sample_due`、DHCE 停钟复位契约、OSER10 RESET
配对 multicycle、跨层级 CE 图求值、行级预解码、音频/复位/CDC/CST。

## 验收结果

| 项目 | 门槛 | 实际 |
| --- | --- | --- |
| Setup | ≥ +0.03 ns | **+2.764 ns** |
| Hold | ≥ 0 | +0.194 ns |
| Recovery | 无违例 | +7.841 ns，0 |
| Removal | 无违例 | +0.253 ns，0 |
| 四类违例 | 全零 | 0/0/0/0，TNS 四时钟均 0.000 |
| 未布通 | 0 | 0 |

STA 分析 194,469 条路径、96,371 个端点；setup 延迟模型 Slow 0.873V 0C C1/I0，
hold 模型 Fast 0.927V 85C C1/I0。最差路径全部位于 `physical_string_bank`
（audio_clk 域，21 级）；渲染器最差 `text_enable_q` 为 +3.587 ns，不再是瓶颈。
`pixel_clk` 实际 Fmax 40.422 MHz，约束 36 MHz。

资源：Logic 70165/138240 (51%)，LUT 55646，ALU 14519，Register 32552 (24%)，
CLS 46733/69120 (68%)，BSRAM 200/340，DSP 113.5/298，I/O 31/297，
IOLOGIC 8（OSER10 4），PLL 2/12，DHCE 1/24。保留 PR1014 `sys_clk_d`
通用布线警告（stage65、66c 同有）。

回归 143/143 全过、零失败。半速光栅用例随半速渲染器一同退役（144→143），
已在套件声明中写明，非静默减少。官方器件模型 3 项全过：单 PLL/OSER10 的
2000 字串化与相位比值、PLL 启动、12 组复位相位停钟契约含提前开钟负向用例。
新光栅逐像素验证两整帧；面板等价对照 4,608,000 像素与冻结 66d 渲染器无差异；
引脚级整机用例 ON=14、OFF=14、writes=14、13840 帧、4245 非零，与 66e 一致。

SDC 按新网表重新生成（未沿用 66e），CE 证明、压缩等价、4 项层级负向测试全过。

引脚审计：31 端口全部显式约束，无重复定位/重复 IO/缺属性/缺约束。四对 TMDS
差分落在同一 IO site 的 A/B 两侧且 `diff_pair` 互指：G15/G16(IOR105)、
J14/H14(IOR103)、J15/H15(IOR101)、K17/J17(IOR58)，均 LVCMOS33D / NONE /
DRIVE=8 / Bank3 3.3V，与官方 `hdmi.cst` 及已验证探针逐字一致。
`hdmi_tx_enable` 在 K14/3 上拉。四时钟全部显式约束。
注：MCP 引脚审计不支持配对 IO_LOC 语法，将 N 端报为"自动分配"并给出
`clean: false`，原始结果保留在 `pin_audit_raw.json`，P/N 已逐对人工核对正确。

哈希：
- 位流 `a233b9e01dbe3ec52d9eb068ffb5f3fa2095d69100aabb3a43fbc4ef1ca246d5`
  （40,855,221 字节，Device Version C / GW5AST-LV138PG484AC1/I0）
- SDC `cad29cfb1016181fb7ea3e9ae6ab92414405adcfecb1f54111b7834007a798d2`
- CST `40d0e3c759cc31d60439c30a204d7dc0184d79b01c7d4fcd3e03a6ccf9c41c88`
- 网表 `89f7a67068bff71aeda019924d23ffa3bd31ba5ed32e13eaa1172e13eb54847c`

## 烧录

固定参数 `--device GW5AST-138C --chain_index 0 --cable-index 4 --frequency 0.5MHz`。

1. `--scan`：USB Debugger A，1 device，ID `0x0001081B`，型号相符，见 `stage67_scan.log`。
2. 操作 69，Flash `0x000000`：`Program and Verify flash successfully.`，
   175.84 秒，退出码 0，见 `stage67_flash_op69.log`。
3. 写入校验成功后执行操作 1：Reprogram / Finished，0.19 秒，退出码 0，
   见 `stage67_reload.log`。

两份日志零 error / fail / warn。本次覆盖板上原 800x600 彩条探针位流；
stage65、66e 及探针位流均有归档可回烧。

## 上板观察

用户实测确认：**画面正常、有声音、灯带跟随**。

仅此三项经实物确认。以下尚未观察或测量，不得据本记录声称：动作到音频的
整机延迟、32 独立谱峰、12 键灯带逐键位置、菜单各项、冷启动重复性、
长时间稳定性、另一台显示器的兼容性。

## 已知可选项

DHCE 停钟仍在（1/24）。它原为消除 recovery 违例而引入，代价是 TMDS 时钟
通道在复位期间会停。当前 setup 余量 +2.764 ns，具备去除条件，使 FCLK 常转；
官方参考流程即为常转。需另开候选目录重跑，本版未做。

`pixel_clk` 实际 Fmax 40.422 MHz，理论上够 800x600@60 的 40 MHz，但仅余
0.4 MHz，过于贴边。@56 为较旧的 DMT 变体，现场更换显示设备存在不被接受的
风险，如需 @60 应先优化再提升。

PHY 停钟契约测试的 215.488 ns 阈值按 1080p30 的 16 PCLK 设定，36 MHz 下
实际为 444.4 ns，检查仍成立但文本偏旧，未修改。
