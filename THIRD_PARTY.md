# 开源来源与许可证

本仓库采用按目录保留许可证的方式，不以一个根许可证覆盖第三方作品，也不表示上游为本参赛版本背书。

| 组件 | 上游与基线 | 许可证/声明 |
| --- | --- | --- |
| FPGAvedio / Mineradio | https://github.com/XxHuberrr/Mineradio-paused ，`d43de565acabfdc1a9c9820a27e81a98ccbebcef` | [GPL-3.0-only](host/mineradio/LICENSE)、[NOTICE](host/mineradio/NOTICE.md) |
| 小智 ESP32 | https://github.com/78/xiaozhi-esp32 ，v1.9.4 `3ced7709c65a39494f5684e99111854a5bcbd8c7` | [MIT](firmware/xiaozhi-v3/LICENSE) |
| Basic Pitch / TensorFlow.js | npm 锁定版本 Basic Pitch 1.0.1 / TFJS 3.21.0 | [前端第三方声明](host/instrument-web/THIRD_PARTY_LICENSES.md)；模型和 WASM 经构建时复制并带许可证 |
| 其他播放器依赖与适配 | 随对应源码保留 | [播放器适配声明](host/mineradio/docs/THIRD_PARTY_PORTS.md) 与 package-lock.json |

团队修改包括 FPGA 乐器逻辑、跨组件曲谱协议、压力键/琴弦演奏、BLE 工作台、平台适配和测试。上游名称、图标、作者版权与声明保持原归属。第三方音乐服务的版权、账号权限与服务规则不因本项目而改变；仅使用有权访问的音频，不提供绕过 DRM 的承诺。
