# FPGA 乐器网页上位机

## 目标

本目录是电脑端和后续 Android WebView 共用的静态前端。MIDI 解析、曲谱编译、协议编码和传输适配分层维护。

## 命令

- `npm test`：运行 MIDI、编译和协议单元测试。
- `npm run check`：检查所有浏览器模块语法。
- `npm run build`：把静态文件复制到 `dist/`，供本地服务器和 Web2BlueBuilder 使用。
- `npm run test:audio`：使用 ffmpeg 生成参考 MP3，再执行真实浏览器转谱验证；先构建。

## 边界

- 不在前端猜测 FPGA 播放状态；只有设备 ACK 才能显示已上传或已开始。
- MIDI 不支持项必须显示给用户，不能静默丢弃后宣称完整演奏。
- 当前交付默认 ESP32-S3 BLE，用户于 2026-10-24 授权增加原生 USB 串口备用；必须手动断开后切换，不自动重放命令。`src/usb-transport.js` 管理 USB 会话和传输选择，`src/transport.js` 只负责原始串口生命周期。板端 ACK 与桥接 ACK 分开处理。
- 协议预览是文本导出，不等于已经连接硬件。
- MP3 转谱已获用户授权接入 Basic Pitch、TensorFlow.js/WASM 和 esbuild；锁定依赖并把模型、运行库与许可证打包到 dist，不依赖运行时外部 CDN。其他依赖按需评估。

## 目录

- `src/midi.js`：SMF 0/1、PPQN、tempo map、音符事件。
- `src/audio.js` / `src/audio-worker.js`：本地音频解码、可取消 WASM 转谱与试听；不上传用户音频。
- `src/protocol.js`：CSV、JSONL 和行协议预览。
- `src/transport.js`：原生 USB Web Serial 收发；连接与板端就绪分开表示。
- `src/ble-transport.js`：Web Bluetooth GATT Central，NUS 默认值、可配置 UUID、Notify、Write/Write Without Response、分片和断线清理。
- `src/app.js`：页面状态、轨道选择和钢琴卷帘。
- `test/`：Node 原生单元测试。
