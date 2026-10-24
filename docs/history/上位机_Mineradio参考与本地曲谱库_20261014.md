# Mineradio 源码参考与本地曲谱库开发记录

日期：2026-10-14。延续拓展四的共享网页路线，本批实现本地曲谱管理与 BLE 生命周期修正。未引入 Electron、未部署网站、未烧录，不改变 V3 硬件引脚与音频时钟。

## 参考依据与适用范围

参考仓库：[XxHuberrr/Mineradio-paused](https://github.com/XxHuberrr/Mineradio-paused)，锁定提交 `d43de565acabfdc1a9c9820a27e81a98ccbebcef`。通过 GitHub REST 读取 README、package.json、本地曲库、播放快照及桌面入口相关实现；完整克隆因本机 gh GraphQL 认证错误失败，未运行该项目安装脚本。

| 源码 | 观察到的做法 | 本工程采用方式 |
|---|---|---|
| [desktop/local-music-library.js](https://github.com/XxHuberrr/Mineradio-paused/blob/d43de565acabfdc1a9c9820a27e81a98ccbebcef/desktop/local-music-library.js) | 版本化索引、受限字段与容量、持久化成功后更新记录 | 曲谱快照版本 1、字段白名单、容量校验、保存失败不替换旧值 |
| [09-queue-snapshot-autoplay.js](https://github.com/XxHuberrr/Mineradio-paused/blob/d43de565acabfdc1a9c9820a27e81a98ccbebcef/public/js/modules/05-playback/09-queue-snapshot-autoplay.js) | 播放列表和当前曲目状态快照、恢复入口 | 保存音轨、速度、力度；用户主动打开，恢复时不自动播放、不发 FPGA 指令 |
| [desktop/main.js](https://github.com/XxHuberrr/Mineradio-paused/blob/d43de565acabfdc1a9c9820a27e81a98ccbebcef/desktop/main.js) 与 package.json | Electron 本地服务入口、Windows 安装包配置；部分窗口显式设置隔离与沙箱 | 保留作后续桌面封装参考，当前执行原方案的浏览器实现 |

Mineradio 是音乐播放器，不能据它的曲库或 PCM 播放能力认定 FPGA 曲谱上传协议已具备。其采用 GPL-3.0-only；本批仅参考设计思路，自行实现适合现有原生 JS 页面的模块，未复制其源码、品牌图标或视觉资产。

## 本批实现

代码位于 `host/instrument-web/`。

- `src/score-library.js`：保存解析后的 MIDI / 音频转谱音符、警告、部分转谱标识、文件名、音轨选择、速度和力度。保存原始音符时间与力度，恢复时复用 `compileTracks`，避免二次缩放。
- 页面增加“我的曲谱库”，支持搜索、打开、更新当前存档、JSON 导出/导入、移除与撤销上次移除。导入备份保存为新记录，避免覆盖同名已有曲谱。
- 浏览器 localStorage 保存版本化快照；最多 20 首，总快照上限 2 Mi 字符、单曲最多 50000 音符。配额/禁用/损坏/版本不兼容给出错误，禁止静默覆盖损坏存档。曲谱库不是 FPGA 曲谱 RAM，不能把其容量当作 FPGA 支持容量。
- 存档不包含原音频、机器文件路径、蓝牙权限或连接状态。打开存档清除之前的原音频预览，防止试听不相关的旧音频。刷新后列出曲谱，但不自动打开、发声或控制硬件。
- 转谱期间禁止打开/导入/保存库记录，避免结果覆盖；不同浏览器、不同网站来源的曲谱库独立，清理浏览器数据会丢失本地记录，JSON 存档用于备份。
- BLE 短 UUID 转为标准 Bluetooth base UUID；按设备名称筛选时可发现未广播目标服务 UUID 的设备，但仍只申请配置服务的访问权限。
- 连接期间禁止切换传输方式；逐会话隔离写队列，分片发送期间断线、末片断线均拒绝发送成功，旧连接异步返回不清除新连接。待发字节复制保存，防止调用者修改原数组改变命令。
- Notify 的 UTF-8 流解码跨分片保留状态；仍为通信日志，不擅自解释为 FPGA ACK。

## 验证范围

新增 Node 原生测试覆盖曲谱保存与恢复、音频转谱元数据、JSON 往返、损坏数据拒绝覆盖、容量与存储失败、移除撤销；BLE 测试补充发现过程中断线、部分写入失败取消后续命令、最后一片断线、重连会话隔离和设备选择窗口互斥。

浏览器脚本扩展了真实 MIDI 导入、保存、刷新恢复、搜索、移除撤销、导出再导入，以及模拟 BLE 收发、跨通知 UTF-8、模式切换锁定与手机宽度检查。最终运行结果见本文末尾验收记录；模拟 BLE 不证明 V3 硬件通过。

## 后续顺序

1. 冻结 V3 S3 GATT 服务与板端协议能力/ACK 合同，保留现有短命令探路；NUS 只是网页默认配置。
2. 完成 FPGA 曲谱 RAM 接收、逐块校验/应答、提交、取消与本地调度；与 `SONG1` 编码器统一测试向量。收到真实 ACK 才开放就绪/上传成功状态。
3. 接入网页上传进度、取消、超时、重试及按板端能力检查容量；弱连接与重连测试通过后做整链路 V3 验收。
4. 复用静态前端完善安卓桥或 Windows 桌面封装；是否引入 Electron 以用户后续交付要求为准。云音乐搜索、账号和 Mineradio 3D 舞台不属于当前拓展四的优先链路。

## 本批验收结果

- `npm run build`：成功，含模块语法检查与 Node 单元测试 **33/33**；静态资源已生成到 `host/instrument-web/dist/`。
- `npm run test:browser`：Edge 沙箱外运行通过；真实 MIDI、库记录保存/刷新恢复/搜索/删除撤销/导出导入、串口与 BLE mock、手机布局及零脚本异常检查通过。
- `npm run test:browser -- --audio`：最终构建通过。已有本机合成 MP3 样本经真实 Basic Pitch/WASM 得到 6 音符；40 秒样本前 30 秒得 6 音符、整首得 12 音符，试听启停、取消与解码错误处理通过。仅证明测试样本，不代表任意歌曲准确率。
- 图片：`host/instrument-web/evidence/library-ble-mobile.png`；备份往返样例：`host/instrument-web/evidence/library-roundtrip.json`。
- 失败也保留结论：沙箱内 Chromium 调试接口 `Runtime.enable` 超时；授权沙箱外运行后可进入页面。本机 Chrome 的默认样式检查得到 `head display:inline` 而非 `none`，未通过；按原脚本默认 Edge 完成最终验证。
- 未做 V3 BLE 实机、S3 UART、FPGA 整曲上传、时序构建、烧录或网站发布。上述“通过”不延伸到这些范围。
