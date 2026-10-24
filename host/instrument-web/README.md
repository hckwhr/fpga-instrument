# FPGA 乐器上位机（BLE 版）

这是一个静态网页上位机，提供 MP3 等音频的本地自动转谱、MIDI 转换及 ESP32-S3 BLE GATT 通信。2026-10-20 起页面只保留 BLE，移除经典蓝牙及 USB 串口入口。点击“连接 BLE 设备”，选择“行者无疆”即可；无需系统配对。使用发布网站无需安装软件，开发构建需安装锁定的 npm 依赖。

## 运行

首次开发运行 `npm ci`，随后构建并服务 dist（源文件中的 Worker 依赖需先打包）：

```powershell
npm run build
python -m http.server 5173 --bind 127.0.0.1 --directory dist
```

访问 <http://127.0.0.1:5173/>，或在线使用 <https://hckwhr.github.io/fpga-instrument-web/>。不要双击 HTML：ES 模块和后台 Worker 需要 HTTP(S) 环境。

## 当前能力

2026-10-20 核对：已烧录 stage59b FPGA 启用了 SONG2 上传、存储与播放链。配套 [ESP32-S3 转发固件](../../firmware/esp32s3-bridge/README.md)为 stage51 引脚版本，使用默认 NUS UUID、Write With Response / Notify、9600 8N1；其构建及转发核心测试已有证据，S3 实际烧录状态和无线联调仍待确认。不能用历史 stage48 二进制替代。

- MP3/WAV/FLAC 等浏览器可解码音频 → Basic Pitch 本地模型 → 音符事件；音频不上传。
- 前 30 秒或整首转换，识别门槛、最短音符调整，后台进度和取消；取消解码需等待浏览器解码返回，推理阶段直接终止 Worker。
- 原音频播放和识别音符试听，试听采用浏览器三角波包络，用于比较音高节奏，不能代表板卡实际音色。
- Standard MIDI File 0/1、PPQN 时间基准和全局 tempo map。
- Note On/Note Off、力度、同音重叠和多轨选择。
- 轨道统计、总时长、最大同时发声数和未支持事件提示。
- 速度 50%～150%、力度 25%～125%转换。
- 钢琴卷帘预览。
- 导出 CSV、JSONL 和协议预览文本。
- 本地曲谱库：保存 MIDI/音频转谱音符及音轨、速度、力度；按曲名搜索、打开、更新、移除/撤销，导出/导入 JSON 存档。刷新后保留曲谱，不自动播放或发送硬件命令。
- 板端短命令控制：连接后点击“识别设备”，收到兼容 HELLO 才开放内置曲目 PLAY/STOP/STATUS；板端状态与浏览器试听、当前网页曲谱分开显示。
- SONG2 上传与播放控制：能力应答门控、会话/请求编号、分块 ACK、CRC、重试和取消；按当前轨道、速度/力度编译，选择 LCD 单声部旋律轨。扩展 CAPS 可启用上传曲谱 PLAY/STOP/STATUS，与原内置曲目按钮分开。stage59b 已包含接收器，页面仍必须取得当前设备 CAPS，不将 HELLO 当作上传能力。

## 边界

音频转谱适合旋律清晰、配器简单的音频，不承诺还原任意流行歌曲；没有人声/伴奏分离，也没有音符编辑器。识别模型力度只是估计，未保留弯音；可调整门槛、最短音符后重新识别。NCM 等专属音频和 LRC 歌词不支持。音频上限 80 MB，整首上限 10 分钟；解码仍需整个文件，低内存手机请用短片段。模型和 WASM 随静态资源打包，不需要外部 CDN；安卓 WebView 的 Worker/WASM 兼容性尚未真机验证。

不把串口已打开或字节写入当作 FPGA 已接收歌曲。MIDI 的 SMPTE 时间会拒绝，SysEx 有提示；打击乐、弯音、特殊控制器和 CC64 踏板还没有完整兼容处理，当前转换可能与原曲不同。

“我的曲谱库”只保存在当前浏览器、当前网站来源中，最多 20 首、总快照 2 Mi 字符、单曲 50000 个音符；这是上位机存储上限，不是 FPGA 容量。浏览器空间不足会明确报错，不删除已有记录。存档包含转谱提示和原始音符，不包含原音频或 MIDI 文件本体；打开存档后原音频试听需要重新选择文件。浏览器清理数据会删除曲谱库，建议用“导出当前存档”或列表“导出存档”备份。JSON 存档与 CSV/JSONL 音符导出格式不同，不能互相代替。不同站点或端口的曲谱库不共享。

页面只使用 BLE，通过服务 UUID 筛选设备；高级配置默认匹配当前桥接固件。用户已确认“行者无疆”可以连接本地上位机；无线连接成功仍不代替 FPGA 上传及播放的实际验收。

V3 使用 ESP32-S3 内置 BLE：点击“连接 BLE 设备”，保持默认 NUS 服务与特征 UUID；stage51 固件已使用这些 UUID。写入按 20 字节分片排队，通知按字节流解析。BLE 连接成功不能证明 FPGA 已接收或执行。实际 UART 是 **S3 GPIO17 TX → FPGA A20 RX（J13-15），FPGA A21 TX（J13-17）→ S3 GPIO18 RX**，3.3V 逻辑并共地；A15 是 ADC 时钟，不能接 UART。管脚依据为 [V3 实际引脚适配](../../docs/hardware/V3实际引脚与程序适配_20261015.md) 的原理图映射。Web Bluetooth 需要 HTTPS 或 localhost，主要支持 Chrome/Edge；iOS Safari 和微信内置浏览器不在默认支持范围。

“板端内置曲目控制”匹配 stage42 `hc05_link.v` 的短命令协议，该 RTL 支持 PING/HELLO/PLAY/STOP/STATUS。收到 `OK,HC05,1,9600,8N1,DEMO=TWINKLE+ODE` 才识别为兼容协议；这不表示已烧入当前连接的板卡。网页控制的是板上选定的内置曲目，不是网页曲谱库中的歌曲。模式/计数显示最近一次 STATUS，不用网页时钟推断进度；PLAY/STOP 的 ACK 不代表音频测量证据。3 秒超时后要求重连，执行结果未知，不自动重发。

展开“通信测试”仍可发送 PING 或自定义文本，默认附加 LF；此后进入调试模式，需要重连后才能使用结构化板端控制，以免手动命令的迟到应答混入新请求。断开蓝牙/串口不会停止板上演奏，必要时使用板载停止入口。详细合同与验收见 [短命令开发记录](../../docs/上位机_板端短命令联调_20261014.md)。

SONG2 已有网页事务、编号播放控制与 FPGA 接收/存储/跨时钟播放验证；当前 stage59b 已通过 128 项 RTL 回归、P&R 与烧录验收。此次网页 67 项测试、构建和浏览器模拟收发检查通过。COMMIT ACK 前不显示上传成功，提交不自动播放；状态是最近一次 ACK，不是实测声音。上传曲谱保存在 FPGA RAM，播放启动后不依赖持续发送，但断电丢失；内置 ROM 曲目可重新上电直接演奏。上传容量为 512 个事件字（一次起音和一次释放各占一字），并非 512 首或 512 个完整音符。真实 BLE、S3 外设调度及实物灯带/声音仍需到板验证。音频转谱和含未支持事件的 MIDI 会被严格编译检查阻止，不自动忽略警告。协议见 [SONG2 开发记录](../../docs/上位机_SONG2可靠曲谱上传_20261014.md)，发布见 [DEPLOY.md](DEPLOY.md)。

## 拓展四演示顺序

1. 不连接电脑，使用板上内置曲目入口，检查曲目节奏、音频与 LED 指引。这是脱机基础演示。
2. 本地构建并打开页面，连接已安装 stage51 桥接固件的 S3；点击“识别设备”，再点击“检查上传能力”。必须收到真实 CAPS，不能以已连接代替。
3. 导入 MIDI（可先用 `test/fixtures/fpga-scores/twinkle.mid`），选择旋律轨，执行上传。等待 COMMIT 确认后，用“上传曲谱”区域的播放按钮启动。
4. 检查 LCD 进度、灯带及声音，再断开网页连接，确认板端继续演奏并自然结束；重新连接后查询状态。菜单/实体停止入口仍应可停止演奏。

当前曲目灯光按 C、C♯、D……B 的十二音级位置显示。脱机按键跟练先用半音排列的“同音色”键盘模式；“钢琴音色”模式采用跨八度白键排列，当前曲目灯光尚未转换为该模式的物理键位提示。

独立 Android APK、联网曲库下载、键位自定义和录音回传尚未交付；网页本地曲谱库与文件导入不代表这些功能已经实现。

## 目录与交付

- `index.html` / `styles.css`：电脑端和后续 Android WebView 共用的界面。
- `src/midi.js`：MIDI 解析和事件编译。
- `src/audio.js` / `src/audio-worker.js`：浏览器解码、后台 WASM 推理、转谱及音符试听。按 Basic Pitch 1.0.1 帧参数运行，逐窗释放张量，避免整首保留中间推理数据。
- `src/protocol.js`：CSV、JSONL 和 FPGA 行协议预览。
- `src/transport.js`：Web Serial 连接生命周期、UTF-8 流接收、有界发送队列与锁清理。
- `src/ble-transport.js`：Web Bluetooth GATT 服务发现、Notify、响应/无响应写入、20 字节分片队列、UUID 校验和会话隔离。
- `src/device-session.js`：短命令匹配、受限行解析、单请求应答、超时与断线失效，保留原始调试收发模式。
- `src/score-upload-protocol.js` / `src/score-upload.js`：SONG2 帧与可靠上传事务；与短命令共享链路互斥。
- `tools/score-receiver-model.mjs`：测试用接收器，非 ESP32/FPGA 固件。
- `src/score-library.js`：本地曲谱快照、版本与字段校验、容量限制、JSON 备份与恢复。Mineradio 参考与本批记录见 [开发记录](../../docs/上位机_Mineradio参考与本地曲谱库_20261014.md)。
- `dist/`：`npm run build` 生成的静态资源，可直接交给 Web2BlueBuilder。

## 验证

```powershell
npm test
npm run check
npm run build
npm run test:browser
npm run test:audio
npm run test:v3-offline
```

构建会先执行语法检查及单元测试。浏览器检查默认使用本机 Edge，可通过 `CHROME_PATH` 指定其他 Chromium；检查项目子路径、桌面/手机布局、本地曲谱库完整往返与模拟串口/BLE 收发，截图保存在 `evidence/`。模拟通过不代表 V3 BLE 或 FPGA 联调完成。受限执行环境可能使 Chromium 调试接口超时，测试运行所需权限应由执行环境显式授予。

`test:audio` 需要本机 ffmpeg，生成自有 C4/E4/G4 单音加和弦的 MP3，再用真实浏览器与真实模型识别，检查六个音符、起音误差、试听停止和取消恢复。合成样本通过不能证明真实歌曲识别质量；需使用者对比试听。

`test:v3-offline` 使用本机 ModelSim 与已编译的生产 C 转发核心，验证网页编译结果到 stage59b 真实 RTL 的 UART、脱机播放、PT8211 和 WS2812 输出；它不运行 BLE 无线电。默认在独立 ASCII 目录 `E:/Gowin/workspace/v3_ext4_stage60_20261019` 仿真，可用 `V3_OFFLINE_BUILD_ROOT` 指定其他 ASCII 路径，日志归档到 `artifacts/ext4_stage60_20261019`。不修改已验收 FPGA 构建、不重新烧录。

2026-10-20完整运行通过：8个事件一致，6个实际RTL应答通过网页CRC/编号/状态校验，PT8211检查12470帧、间隔1024拍且无削波，WS2812检查171帧并完成C/E/G→D→熄灭，停止发送后仍自然结束并清音。当前61个生产源文件与已烧录stage59b验收清单哈希一致。详见 [验证记录](../../artifacts/ext4_stage60_20261019/validation.md)；此结果不是实物无线验收。
