# 发布到 hckwhr 的 GitHub Pages

## 当前版本：BLE 专用版（2026-10-20）

部署提交：`b7add129a30c76c49af7437f7011a15ede6f1c82`，Pages 状态 `built`（2026-10-20T10:24:53Z）。

67 项单元测试、本地及线上 Edge 浏览器回归全部通过；蓝牙链路采用显式 GATT 模拟，实物连接沿用用户已确认的结果，不代表整曲无线上传验收。

当前页面只保留 ESP32-S3 BLE，删除经典蓝牙/USB 串口入口与波特率选择。点击“连接 BLE 设备”，选择“行者无疆”，默认 UUID 无需修改。使用支持 Web Bluetooth 的 Chrome/Edge，通过 HTTPS 或 localhost 打开，无需系统设置配对。

保留 MP3 转谱、MIDI、曲谱库、主题、设备识别、内置曲目控制、SONG2 上传与播放控制；执行结果仍须真实 FPGA 应答。用户已确认本地实物 BLE 连接；完整无线上传与声音观测需要继续到板验证。

更新时运行 `npm run build` 与 `npm run test:browser`，仅将 dist 内部文件更新到独立部署仓库的 main 根目录。历史 Web Serial 模块及测试保留在本地，不接入 UI、不发布。推送后等待 Pages 完成，再运行 `npm run test:browser -- --site=https://hckwhr.github.io/fpga-instrument-web/` 验证线上资源。记录见 `artifacts/instrument_web_ble_20261020/validation.md`（工作区根目录）。

以下内容为 2026-10-03 旧版部署历史，其中串口连接及上传能力描述不适用于当前版本。

## 历史记录

公开仓库：<https://github.com/hckwhr/fpga-instrument-web>。
在线网址：<https://hckwhr.github.io/fpga-instrument-web/>。
日夜主题版本（2026-10-03）部署提交：`4353ea9f49d3d5ee4b2f8b70cf38309a893e238f`，Pages 状态 `built`。线上 Edge 日夜切换、记忆恢复、画布同步、桌面/手机布局及模拟串口回归通过；本地构建、11项单元测试与真实 MP3 回归通过。顶部按钮显示当前模式，点击切换，默认白天并记住选择。
2026-10-03 经用户授权创建并发布，Pages 使用 `main` 分支根目录。暖色工作台版本部署提交：`ab5509ef81fb70d06088bf1ad2573e975ddf4060`；上一版 MP3 转谱提交为 `daf4086df4403ca83928a6e38a2de35313eca700`。
暖色版本 Pages 状态为 `built`；线上桌面/手机布局、标签键盘切换、设备折叠入口和模拟串口回归通过。本地重新执行11项单元测试及真实模型 MP3 回归通过，视觉评审见 `UI_DESIGN.md`。
已确认该提交的 Pages 状态为 `built`。线上 Edge 浏览器通过真实模型 MP3 转谱、音符试听启停、解码失败和取消恢复检查；40 秒样本在前 30 秒模式得到 6 个音符、整首得到 12 个，后段和弦起音误差小于测试容差 200 ms。测试样本由本机合成，不能据此宣称真实歌曲识别准确率。真实 HC-05 联调尚未进行。
这是 GitHub 提供的免费项目网址，无需购买独立域名。仓库包含静态网页、Basic Pitch 模型、WASM 运行文件及许可证，开发脚本和 FPGA 工程保留在本地。

## 最小发布方式

1. 首次运行 `npm ci`，然后运行 `npm run build`，检查 `dist/`。其中包括模型和 WASM 资源，不包含 FPGA 工程或本机资料。
2. 新建公开 GitHub 仓库 `fpga-instrument-web`，将 **dist 内部文件** 放在仓库根目录（index.html 在根目录）。
3. 仓库 Settings → Pages → Build and deployment：选择 Deploy from a branch，分支 main，目录 / (root)。
4. 等部署成功，再打开上述网址。不要把整个“高云”工作区上传到仓库。

更新时重新构建并更新仓库中的对应静态文件即可。本页不需要后端、密钥或外部 CDN。所有资源引用均为相对路径，适合项目子路径托管。MIDI 文件在用户浏览器本地解析，不上传到服务器。

独立域名（例如你购买的 music.example.com）属于后续可选功能，需要购买或已有域名、配置 DNS 和 Pages Custom domain；这里不创建不存在的 CNAME。

## 在线蓝牙条件

HTTPS 网址允许兼容浏览器使用 Web Serial，但不会消除系统配对或浏览器的设备授权提示，这些必须由使用者点击完成。
Windows 先配对 HC-05，再使用新版桌面 Chrome/Edge 选择 SPP 串口；系统和浏览器需能暴露对应串口。实际兼容性要等 HC-05 到手验证。
HC-05 是经典蓝牙 SPP，不是 BLE；安卓 Chrome 不能借此页面直接连接 HC-05。安卓手机可以浏览、导入和转换曲谱；蓝牙需要后续 Web2BlueBuilder 原生 SPP 桥的 APK。

V3 的网页路径选择“BLE（ESP32-S3）”，由 Web Bluetooth 连接 S3 的 GATT 服务。页面默认显示 NUS 兼容 UUID，S3 固件若使用自定义服务，必须填入实际服务/写入/通知特征 UUID；当前本地文档没有把 NUS 认定为 V3 最终 UUID。Web Bluetooth 需要 HTTPS 或 localhost，且需要用户主动点击选择设备。网页端完成分片写入和 Notify 接收不等于 FPGA 执行成功，仍需 S3 UART 与 FPGA ACK 的硬件联调。

当前实现的是连接、断开、文本收发和错误状态。板端仍是独立《小星星》固件，尚无通用曲谱 UART 接收器；协议预览不是已冻结上传协议，页面不发送整曲、不显示“上传成功”。
