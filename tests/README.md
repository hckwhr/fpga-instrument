# 回归参考资料

- `fixtures/rtl-stage47/`：生产 C 桥接测试使用的固定 RTL 请求/应答黄金向量，来源保持不变。
- `reference/stage42/hc05_link.v`：旧设备识别应答词汇的固定参考，不是当前链路实现。
- `reference/stage59b/`：旧的 9600 波特率离线 UART→DAC/灯带整机仿真参考，并非当前烧录版本。
- 当前 136 项 FPGA 仿真在 `fpga/stage64/sim/`，共用前端测试在 `host/instrument-web/test/`，桌面软件测试在 `host/mineradio/tests/`，桥接/语音测试在 `firmware/esp32s3-bridge/tests/`。

保留参考资料是为了不删减已有套件。生产源码和历史参考是不同用途，不应混用其验收结论。
