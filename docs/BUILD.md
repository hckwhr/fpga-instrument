# 构建与测试

本仓库不带工具链、node_modules、ESP 托管依赖和个人配置。建议克隆到 ASCII 路径，例如 `E:/Gowin/workspace/fpga-instrument`；Gowin/ModelSim 对中文工作路径的支持有限。下面均从仓库根开始，命令不会自动烧录。

## 上位机

工具：Node.js 24、npm、PowerShell 7。首次安装两个组件的锁定依赖：

```powershell
cd host/instrument-web
npm ci
npm run build
cd ../mineradio
npm ci
npm run prepare:fpga
node --test tests/*.test.js
npm run build:fpga:dir
```

桌面产物为 `host/mineradio/dist-fpga/win-unpacked/FPGAvedio.exe`。可直接运行该文件；不需要使用有本机硬编码路径的历史 deliver-desktop.ps1。

真实浏览器/模型检查需 Edge/Chromium，音频样本生成需 ffmpeg：

```powershell
cd host/instrument-web
npm run test:audio
cd ../mineradio
npm run test:app
node tools/desktop-smoke.mjs
```

Android 构建工具及路径见 [README-FPGA.md](../host/mineradio/README-FPGA.md)，核心入口为 `npm run build:android`；历史脚本中的 JDK/SDK 路径须按实际安装调整。编译 APK 不等于手机真机验收，不上传签名私钥。

## FPGA

当前工程为 `fpga/current/v3_hdmi_top.gprj`，顶层 `v3_hdmi_top`，31 引脚、4 时钟。工具为 PowerShell 7、ModelSim 与 Gowin V1.9.12.03。先仿真，再综合和审计，最后运行 P&R。

```powershell
pwsh -NoProfile -File tools/test-fpga.ps1 -BuildRoot E:/Gowin/workspace/fpga-instrument-test -ModelSimBin E:/modelsim/win64
```

测试入口默认复制当前工程到独立 ASCII 路径，完整回归 143 项。官方器件模型另外运行复制目录内的 `sim/run_hdmi_phy.ps1`，传入本机 ModelSim 与 Gowin prim_sim.v 路径。历史版本仍可通过测试入口的 Version 参数选择，不能删减套件求通过。

`tools/build-fpga.tcl` 默认只运行当前 HDMI 工程综合。随后必须针对新综合网表重新执行 CE 审计、SDC 压缩和集合等价验证，核对 setup/hold 成对，再单独运行 P&R。实际使用 place_option=3 / route_option=2；同目录不能并发构建。

生产快照中的准备与压缩脚本包含旧绝对路径，特别是 compact_queries.py 默认网表路径须先核对，不能误用旧网表。原机 prepare_hdmi_constraints.ps1 在末尾同路径复制时报错，尚未整理为跨机器一键发布流程。详细限制见 [当前工程说明](../fpga/current/README.md)。

SDC 不能改为不经证明的全层级通配，不能把旧审计冒充新网表结果。连续串化时钟下保留的复位多周期例外尚需重新论证，见 [验证边界](../artifacts/current/validation.md)。当前工具报告正余量不代表这项审核已结束。

新位流须核对 setup ≥ +0.03 ns、hold ≥ 0、建立/保持/恢复/移除检查、引脚与时钟，以及实际生效约束；归档资源/时序/引脚报告和位流 SHA256 后才能交付。旧源码、日志及失败证据保留，不覆盖原构建目录。

## ESP32

工具：ESP-IDF 5.4.4、ESP32-S3 交叉编译器、CMake/Ninja/Python。先按 Espressif 官方方式激活本机 IDF 环境，在 ASCII 路径构建。小智与桥接目录必须维持相邻，因为共用 bridge_core/voice_core。

```powershell
pwsh -NoProfile -File tools/build-esp32.ps1
python firmware/esp32s3-bridge/tests/run.py
python firmware/xiaozhi-v3/tests/run.py
```

脚本从板型 config.json 生成 fpga.defaults，使用当前板型、N16R8 配置与锁定依赖，不需要原开发机的 E 盘基线。主机 C/C++ 测试在 Windows 需要 Visual Studio 2022 C++ 与 CMake。

当前源代码含 BLE 主用 / USB 备用候选，必须保留板型配置 `CONFIG_ESP_CONSOLE_SECONDARY_NONE=y`，避免 USB Serial/JTAG 驱动与调试控制台竞争；UART0 调试保留。验证机启用 `CONFIG_BT_NIMBLE_USE_ESP_TIMER=y`，2 ms 桥接泵间隔经 NPL/esp_timer 调度，不能据此宣称硬件实际吞吐。固件候选与地址表见 `artifacts/ble_primary_usb_backup_20261024/firmware/`；尚未烧录。历史已验证镜像仍保留。

独立 V3 桥接工程可在 IDF 环境中进入 `firmware/esp32s3-bridge` 执行 `idf.py set-target esp32s3` 和 `idf.py build`，但历史验收尚未覆盖其独立镜像。不得将 fpga-bread-s3 镜像刷到不匹配的 V3 PCB。

ESP 构建不包含设备 NVS/激活信息。首台设备需自行配网和绑定，不能在源码写入密钥。历史串口构建脚本依赖原开发机已解析目录，只保留供追溯，不作为新机器入口。
