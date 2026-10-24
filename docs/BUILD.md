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

工具：PowerShell 7、ModelSim（验收机 `E:/modelsim/win64`）、Gowin V1.9.12.03。先仿真再构建：

```powershell
pwsh -NoProfile -File tools/test-fpga.ps1 -BuildRoot E:/Gowin/workspace/fpga-instrument-test -ModelSimBin E:/modelsim/win64
```

该入口复制当前 FPGA 源码到独立 ASCII 目录，再执行 `sim/run_dynamic_regression.ps1 -Jobs 12`；不修改验收目录。完整套件 136 项，不能为通过而删减。

在 Gowin IDE 打开 `fpga/stage64/v3_hardware_top.gprj`，保留当前器件、PLL、CST、SDC，place_option=3 / route_option=2；同目录只运行一个构建。可使用 `tools/build-fpga.tcl` 的 CLI 模板，先核对本机工具路径与当前工程选项。

SDC 已是经过等价证明的压缩版本，不能改为无保护的全层级通配。若 RTL 改动使网表寄存器命名/覆盖变化，须重新运行半速审计和集合等价检查，保留 setup/hold 配对，并从最终报告核对实际生效内容；不能直接复用旧结果声称新网表通过。归档时序/引脚/资源报告、位流 SHA256 后才考虑烧录。

`fpga/stage64/scripts/` 保留历史审计/诊断脚本，其中部分仍指向旧实验目录。当前测试入口以上述 tools/test-fpga.ps1 为准；旧 archive/prepare/restart 等脚本不作为一键构建入口。

## ESP32

工具：ESP-IDF 5.4.4、ESP32-S3 交叉编译器、CMake/Ninja/Python。先按 Espressif 官方方式激活本机 IDF 环境，在 ASCII 路径构建。小智与桥接目录必须维持相邻，因为共用 bridge_core/voice_core。

```powershell
pwsh -NoProfile -File tools/build-esp32.ps1
python firmware/esp32s3-bridge/tests/run.py
python firmware/xiaozhi-v3/tests/run.py
```

脚本从板型 config.json 生成 fpga.defaults，使用当前板型、N16R8 配置与锁定依赖，不需要原开发机的 E 盘基线。主机 C/C++ 测试在 Windows 需要 Visual Studio 2022 C++ 与 CMake。

独立 V3 桥接工程可在 IDF 环境中进入 `firmware/esp32s3-bridge` 执行 `idf.py set-target esp32s3` 和 `idf.py build`，但 stage64 尚未对其独立镜像完成硬件验收。不得将 fpga-bread-s3 镜像刷到不匹配的 V3 PCB。

ESP 构建不包含设备 NVS/激活信息。首台设备需自行配网和绑定，不能在源码写入密钥。历史 build_uart_stage64.ps1 依赖原开发机已解析目录，只保留供追溯，不作为新机器入口。
