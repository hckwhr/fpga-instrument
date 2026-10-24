# 单仓库整理验证（2026-10-24）

在统一目录内实际运行：

- 共用上位机 `node --test`：106/106，零失败。
- 共用上位机 `npm run check`、`npm run check:board`：通过。
- 桌面端 `node --test tests/*.test.js`：安装 package-lock 锁定依赖后 199/199，零失败；首次缺依赖的两项失败没有通过删套件规避。
- 桥接 `python firmware/esp32s3-bridge/tests/run.py`：2/2 CTest，15 种分片/MTU 组合、1065 次协议往返及 12 组 RTL 黄金交换通过。
- 小智 `python firmware/xiaozhi-v3/tests/run.py`：屏幕锁 CTest 1/1 通过。

本次只适配目录、测试工件位置和依赖锁定，不改 FPGA 生产 RTL/约束。stage64 的 136 项 RTL 回归、P&R、时序和位流使用归档证据，本次没有重复运行 P&R、重新构建 ESP 固件或烧录硬件，也没有重新运行桌面打包/浏览器/无线实测。
