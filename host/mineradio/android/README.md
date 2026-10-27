# FPGAvedio Android

Android 版直接打包 FPGAvedio 的 `public/index.html`、原播放器模块和 FPGA 工作台。保留播放器 / FPGA 播放双模式、背景、歌曲队列、音乐导入、转谱整理、曲谱库，以及波形、频谱、李萨如显示。`mobile.html` 是旧版入口，不再作为 APK 首页。

## 使用

1. 打开 FPGAvedio，点击启动页进入播放器。搜索栏始终位于顶部；左上角菜单打开侧边抽屉，包含音乐首页、当前队列、我的歌单、FPGA 播放、视觉设置、账号和导入音乐。歌单与队列在正文区域打开，不遮挡搜索。原电脑版鼠标贴边自动弹出的行为在安卓停用。
2. 在侧边菜单点击「网易云登录」生成二维码，保存到相册，再用网易云 App 的「扫一扫 → 相册」识别并确认授权，返回 FPGAvedio。也支持另一台设备扫码。授权成功后显示账号名称；登录弹窗提供退出账号。账号有权限的曲目通过同一会话读取，不绕过会员或版权限制。
3. 选择并播放音乐后，首页当前歌曲卡片显示封面、曲名与「当前歌曲 → FPGA」。点击即可切换并导入，首次打开会等待工作台就绪。工作台顶部也保留「导入播放器当前歌曲」，支持直接选择音频 / MIDI。
4. 按「导入转谱 → 整理试听 → 上传演奏」操作。顶部横向功能栏可滚动，包含 BLE 连接和 FPGA 联动。
5. 点击扫描 BLE，允许附近设备权限，选择「行者无疆」。识别设备后上传，再点击播放；停止按钮保留。

返回键从 FPGA 模式回到播放器。切换模式保留工作台、曲谱和连接状态。安装更新沿用现有包名与签名，不清除应用数据。

## 平台适配

- Android WebView 承载原播放器；令牌路径的本地 HTTP 服务提供离线 JS、模型、WASM 和音频。
- 原生 GATT 负责 BLE 扫描、连接、通知和写入，复用既有曲谱协议与设备应答处理。
- 系统文件选择器支持多文件；其他 App 分享的普通音频和网易云歌曲链接可以导入。
- 网易云搜索、音频读取、歌词与扫码授权使用和桌面依赖相同的 weapi 请求编码，通过原生 HTTPS 访问。Cookie 保留在 Android 私有 CookieManager 中，不发给 JS 或写入仓库。二维码由已有 qrcode 依赖离线生成，不发给第三方二维码服务。
- 登录后的个人歌单与歌单歌曲使用原生分页读取，复用桌面版的列表和队列；封面直接从 HTTPS 图片源加载。
- 播放器显式点播后需等待原生下载，WebView 允许本地界面异步启动音频，避免手势过期后无法播放。
- 手机版目前不含电脑版 Node 服务中的 QQ / 酷狗 / 汽水账号接口，不支持 Windows Wallpaper Engine 宿主和桌面窗口操作。USB 串口仍是电脑版备用通道；手机版使用 BLE。
- Android 禁用 SVG 背景位移滤镜并限制 3D 渲染像素密度，保留原视觉场景和半透明配色。

## 构建与测试

在 `host/mineradio` 下运行 `npm run build:android`。工具链路径见 `android/build.ps1`；构建需要既有 JDK 17、Android 34 平台与 build-tools。输出 `android/build/FPGAvedio-Android.apk`。

`node tools/app-smoke.mjs --player` 测试实际 Android 入口，覆盖歌曲播放、模式切换、当前歌曲导入、真实模型转谱、曲谱整理及上传 / 播放 / 停止协议。此测试的原生 BLE 和 FPGA 应答为模拟，实际无线链路仍需连接乐器测试。`npm run test:app` 保留旧入口回归。

`pwsh android/tests/build.ps1` 构建独立设备测试 APK。将主 APK 与 `android/build/device-test/playback-test.apk` 安装到测试手机后，执行 `adb -s <设备序列号> shell am instrument -w cn.xingzhewujiang.mineradio.tests/cn.xingzhewujiang.mineradio.tests.PlaybackInstrumentation`，检查真实网易云二维码等待状态、歌曲下载及 WebView 播放时间推进。测试会打开应用、点播参考歌曲并停止；不会代替用户完成账号授权。不要与手工操作同时运行。

签名密钥保存在本地 `android/signing`，不提交 Git。更新必须使用同一密钥。
