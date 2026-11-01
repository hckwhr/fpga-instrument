# 当前演奏工程实施记录

源码入口为 `fpga/playability/v3_hdmi_top.gprj`，配套 ESP 源码位于 `firmware/`。本目录保存测试日志、约束和实施报告，不包含设备身份及配网信息。

## 功能与测试

- 完整 RTL 回归 150/150 通过，0 失败（127 项当前功能与 23 项兼容配置）；见 `full_regression.txt`。
- 官方器件模型 3/3 通过：PLL 启动频率、串化顺序、停钟复位契约。
- ESP 原生测试见 `esp_native_tests.txt`，包括指定曲目与应答匹配、会话互斥、USB 分帧。
- 仓库副本复测：bridge_core、voice_core、usb_link 共 3 项及 display_lock 1 项通过；15 组分片/MTU 组合、1065 次 SONG2 往返、12 组冻结 RTL 协议交换通过。
- 32 份相位/包络及 8 路物理弦保留。初次整理的 337 个源码、约束和脚本与测试工程逐文件相同；提交整理随后补充了源码说明注释。
- 下表为既有实施结果，源码说明注释和文档整理不修改声音协议，也不代表重新构建 FPGA。

## 实施结果

| 项目 | 实际结果 |
| --- | --- |
| Logic / LUT / ALU | 74313 / 59389 / 14924 |
| Register | 34282 |
| CLS | 49532 / 69120（72%） |
| BSRAM / SSRAM / DSP | 204 / 0 / 125.5 |
| Setup / Hold | +0.019 ns / +0.189 ns |
| 建立 / 保持违例 | 0 / 0 |
| Recovery / Removal 最小余量 | +8.257 ns / +0.354 ns |
| 接口审计 | 31 引脚、4 时钟 |

工具没有单独列出恢复/移除违例总数，也未打印明确未布通计数；实际生成了 `.pr`、时序报告和 `.fs`，不将缺失计数补写为零。

Setup 比项目 +0.030 ns 目标少 0.011 ns。用户知晓后授权上板测试，不将本结果改记为原余量门槛通过。2026-10-30 FPGA 永久写入及校验成功，随后 Reprogram；配套 ESP 固件也已烧录。烧录完成与每项实物功能验证是不同证据，本记录不替代用户的演奏观察。

`project.rpt.txt` 是资源报告，`timing_audit.json` 与 `recovery_removal_audit.json` 提供时序提取结果，`pin_pair_audit.json` 提供接口核对，`resynthesis_equivalence.json` 提供约束输入与实施网表对应关系。`applied.sdc` / `applied.cst` 为实际实施约束。
