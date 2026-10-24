# stage64 验收与产物

验收日期 2026-10-23；统一整理日期 2026-10-24。实际依据为 [verification.json](../artifacts/stage64/verification.json) 和原始报告，而非资源预算。

- RTL 全回归 136 项通过，原 134 项保留，新增高波特率 UART 与生产 115200 音频快照专项。
- 上位机 106 项通过，完整构建、真实 MP3/模型浏览器验证、App 与打包桌面冒烟通过。原始结果随归档保留；统一整理后的测试结果另记 `artifacts/packaging/`。
- FPGA P&R：Logic 69909、Register 32312、CLS 46564/69120（68%）、BSRAM 200/340、SSRAM 0、DSP 113.5/298、I/O 45；未布通 0。
- STA：setup +0.098 ns，hold +0.188 ns，违例 0/0；3 时钟和 4 对 setup/hold multicycle 生效，最终引脚审计 clean。存在 PR1014 通用时钟布线警告。
- 位流 [v3_hardware_top.fs](../artifacts/stage64/pnr/v3_hardware_top.fs)，SHA256 `1b4f6ecc1cf45449713798a20a52289174f56ef2d0d549efb22094cf771f63ed`。
- ESP 小智应用 `xiaozhi.bin`：SHA256 `d1ba5ab56ca9f7824955bf95ee23a50ca8a0e476ca43bc4a1b2e7042e7e157f9`，ESP-IDF 5.4.4 / fpga-bread-s3 / N16R8。烧录分段地址见对应 flash_args，路径与工厂文件相匹配，无 NVS 身份镜像。

**stage64 尚未烧录或实物验证**。230400 只验证到 UART 仿真与有限桥接模型，不是正式速率。115200 模型中的 490 ms 音频快照转发不是 BLE 实测速率。语音、BLE/Wi-Fi 并发和声音主观质量仍需实际硬件验收。

`pnr_running.json` 是历史运行中快照，不是当前状态；以 `pnr/pnr_final.json` 为准。报告中的旧工作站绝对路径是证据的一部分，保留但不是新机器构建入口。
