# 构建方法

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

Android 构建工具及路径见 [README-FPGA.md](../host/mineradio/README-FPGA.md)，核心入口为 `npm run build:android`；历史脚本中的 JDK/SDK 路径须按实际安装调整。签名私钥由开发者本地保存。

## FPGA

新增独立节奏实体跟练候选位于 [fpga/rhythm](../fpga/rhythm/README.md)，
它恢复 HDMI 单屏设置/演奏，保留压力流水和实体跟练协议，完整回归为 163 项。
本候选实际实施状态见 `fpga/rhythm/VALIDATION.md`；使用时，将下文复制源改为
`fpga/rhythm`，不要混用旧工程的 RTL、网表或约束集合。

仓库保留的历史生产入口为 `fpga/playability/v3_hdmi_top.gprj`，顶层 `v3_hdmi_top`，31 引脚、4 时钟。工具为 PowerShell 7、ModelSim 与 Gowin V1.9.12.03。先仿真，再综合和审计，最后运行 P&R。

将 `fpga/playability` 复制到独立 ASCII 路径，从复制目录执行：

```powershell
pwsh -NoProfile -File sim/run_dynamic_regression.ps1 -Jobs 12
pwsh -NoProfile -File sim/run_hdmi_phy.ps1
```

综合使用该目录的 `v3_hdmi_top.gprj`。取得实际综合网表后运行 `scripts/prepare_performance_constraints.ps1 -Netlist <本次综合网表路径>`，再以 place3/route2 完成 P&R。完整说明见 [当前演奏工程](../fpga/playability/README.md)，现有结果见 [实施记录](../artifacts/playability/README.md)。

也可从仓库根使用统一入口复制当前工程并执行完整回归：

```powershell
pwsh -NoProfile -File tools/test-fpga.ps1 -BuildRoot E:/Gowin/workspace/fpga-instrument-test -ModelSimBin E:/modelsim/win64
```

测试入口将当前工程复制到独立 ASCII 路径并运行仿真。官方器件模型入口为复制目录中的 sim/run_hdmi_phy.ps1，工具参数按本机 ModelSim 与 Gowin prim_sim.v 位置设置。

tools/build-fpga.tcl 运行当前 HDMI 工程的综合。后续处理顺序为综合网表生成、CE 分析与约束准备、SDC 压缩、布局布线。P&R 使用 place_option=3 / route_option=2；同目录只运行一个构建。

scripts 目录保留准备与约束压缩工具，使用前应设置当前网表和输出路径。音频共同使能、多周期关系及 HDMI 时钟由 RTL 与 SDC 配合表达；修改模块后，约束集合也应按新网表重新生成。生产脚本中部分路径来自原开发机，需要按本机工具安装位置调整。

FPGA 工程职责划分见 [模块说明](../fpga/playability/README.md)，音频和 HDMI 的关系见 [工程原理](ARCHITECTURE.md)。

## ESP32

工具：ESP-IDF 5.4.4、ESP32-S3 交叉编译器、CMake/Ninja/Python。先按 Espressif 官方方式激活本机 IDF 环境，在 ASCII 路径构建。小智与桥接目录必须维持相邻，因为共用 bridge_core/voice_core。

```powershell
pwsh -NoProfile -File tools/build-esp32.ps1
python firmware/esp32s3-bridge/tests/run.py
python firmware/xiaozhi-v3/tests/run.py
```

脚本从板型 config.json 生成 fpga.defaults，使用当前板型、N16R8 配置与锁定依赖，不需要原开发机的 E 盘基线。主机 C/C++ 测试在 Windows 需要 Visual Studio 2022 C++ 与 CMake。

BLE 与 USB 共用桥接核心。板型配置保留 CONFIG_ESP_CONSOLE_SECONDARY_NONE=y，使 USB Serial/JTAG 用于业务连接，UART0 用于调试输出。CONFIG_BT_NIMBLE_USE_ESP_TIMER=y 配合 NPL/esp_timer 调度桥接任务。

独立 V3 桥接工程可在 IDF 环境中进入 firmware/esp32s3-bridge，执行 idf.py set-target esp32s3 与 idf.py build。fpga-bread-s3 通用套件与 V3 PCB 使用不同板型配置，应分别选择对应工程。

ESP 构建不包含设备 NVS/激活信息。首台设备需自行配网和绑定，不能在源码写入密钥。历史串口构建脚本依赖原开发机已解析目录，只保留供追溯，不作为新机器入口。
