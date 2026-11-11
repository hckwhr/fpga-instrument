# 演示脚本与证据索引

## 三分钟演示

| 时间 | 展示 | 说明重点 |
| --- | --- | --- |
| 0:00–0:20 | 键盘、FPGA、ESP32-S3、HDMI 与音响全貌 | 每个设备的职责；说明本次实际使用的固件版本 |
| 0:20–1:00 | 单键轻重按、双键和弦、摇杆弯音/颤音 | 压力和表情确实影响声音，灯光与琴键对应 |
| 1:00–1:35 | HDMI 波形、频谱、李萨如及设置菜单 | 同时拍到实体操作和显示反馈，保留真实音频 |
| 1:35–2:15 | 上位机读取能力、上传短曲、播放和停止 | 展示板端确认；选准确 MIDI 或已整理曲谱，让节奏容易辨认 |
| 2:15–2:40 | 配套版本下的实体节奏跟练 | 目标键 RGB 指引、错键静音、按对发声；若硬件版本不匹配则改展示已有仿真证据 |
| 2:40–3:00 | 源码和验收结果 | 32 独立声部、163 项回归、STA 结果，说明各自的验证范围 |

不需要为了录求职视频重新烧录未经实物确认的最后版本。使用已知可演示的板上程序，并在视频说明中标注；最新源码的验证结果单独展示。实物图和旧截图可以说明已有实现，不能标成最后单屏版的实测画面。

## 数字与来源

| 可引用内容 | 依据 | 范围 |
| --- | --- | --- |
| 32 独立声部、8 路物理弦 | [最新验收](../../fpga/rhythm/VALIDATION.md)、[声部库](../../fpga/rhythm/rtl/polyphony_bank_32.v)、[物理弦库](../../fpga/rhythm/rtl/physical_string_bank.v) | 最新工程结构及网表审计 |
| 163 项回归、3 项官方模型 | [最新验收](../../fpga/rhythm/VALIDATION.md) | 2026-11-10，非本次文档整理重新运行 |
| Setup +0.556 ns、hold +0.187 ns | [最新验收](../../fpga/rhythm/VALIDATION.md) | 本次布局布线约束下的 STA；不是音频延迟 |
| Logic 72539、CLS 48587 | [最新验收](../../fpga/rhythm/VALIDATION.md) | P&R 资源统计，不能混用综合前数值 |
| 帧前 78 拍数字转换 | [显示优化记录](../../fpga/rhythm/DECIMAL_CHANGE.md) | 正常扫描契约及负向测试，不是整个 UI 的刷新延迟 |
| 上位机 164 项 Node 测试与交互检查 | [节奏 UI 更新记录](../RHYTHM_UI_UPDATE.md) | 记录对应版本，BLE 页面测试使用模拟设备 |
| 物理菜单按键两帧内更新 | [tb_hdmi_menu_refresh.sv](../../fpga/rhythm/sim/tb_hdmi_menu_refresh.sv)、[验收](../../fpga/rhythm/VALIDATION.md) | 引脚级仿真，不表述为最新位流实物测试 |
| ADC/UART 到 RGB、PT8211 | [tb_rhythm_hdmi_pins.sv](../../fpga/rhythm/sim/tb_rhythm_hdmi_pins.sv) | 端到端引脚仿真，声音由串行音频解码确认 |
| 延迟示波器记录 | [基础测试照片](../submission/assets/latency_basic2_scope.jpg)、[视听测试照片](../submission/assets/latency_extension3_scope.jpg)、[技术报告](../submission/README.md) | 需结合报告中的探头接法、测量起止点和工作模式 |

最新实施位流 SHA256 为 `ff40e3adb2035a7261988d1a0774d62428b2bd41358e26e88484d48e5b972549`，用于和本地归档对应。它不证明已烧录。完整报告、SDC 及综合网表哈希见验收文档。

## 显示优化的综合对照

以下数据摘自本机归档 `artifacts/v5_rhythm_hdmi_digits_20261110/PROGRESS.md`，
原始综合报告保存在同目录的 `gwsynthesis`。本次只整理已有结果，没有重新综合。
对照的是 2026-11-08 单屏候选与 2026-11-10 帧前数字预计算候选；两者 RTL
差异位于 `instrument_panel_renderer.v`，不是双屏与单屏的资源比较。

| 综合指标 | 优化前 | 帧前预计算 |
| --- | --- | --- |
| 整机 LUT | 57460 | 57278 |
| 整机 ALU | 14644 | 14648 |
| 整机 Logic | 72104 | 71926 |
| 整机 Register | 34693 | 34810 |
| BSRAM | 177 | 177 |
| 显示模块 LUT | 2514 | 2326 |

综合 ID 为 `d06cf2f74d314aa59fb8a9f8b40067bd`。表内是综合资源；最终实施
资源应读 [VALIDATION.md](../../fpga/rhythm/VALIDATION.md)。原候选 35 条未布通
日志未列出具体网络，不把数字转换宣称为已定位的唯一根因。

## 现成展示素材

| 素材 | 适合说明 |
| --- | --- |
| [作品实物全貌](../submission/assets/instrument_overview_photo.jpg) | 系统完整度，2026-10-31 的实物状态 |
| [V5 PCB](../submission/assets/v5_pcb_photo.png) | 团队硬件与压力键布局 |
| [桌面工作台](../submission/assets/desktop.png) | 已有桌面应用；属于历史截图，未展示最新第三模式 |
| [手机工作台](../submission/assets/mobile_workbench.png) | 移动端适配与连接界面 |
| [系统架构矢量图](../submission/figures/architecture.svg) | 既有系统总体结构；最新入口和状态以首页为准 |

## 面试时建议打开的四个页面

1. [仓库首页](../../README.md)：先说明完整系统。
2. [音符事件契约](../../fpga/rhythm/rtl/note_event_contract.vh)：讲清接口与身份归属。
3. [数字预计算改动](../../fpga/rhythm/DECIMAL_CHANGE.md)：讲一个具体优化与测试。
4. [最新验收记录](../../fpga/rhythm/VALIDATION.md)：展示数据来源和验证边界。

历史记录是追溯材料。文档中标有旧日期的“未实现”“未推送”等描述仅适用于当时；当前代码入口为 `fpga/rhythm`，项目首页是导航入口。
