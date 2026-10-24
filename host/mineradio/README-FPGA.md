# 行者无疆 · Mineradio FPGA App

此目录是 Mineradio 的本地派生版。Android App 内置现有上位机，使用原生 BLE/GATT，不依赖 Web Bluetooth、HC-05、电脑服务器或在线模型。Windows 原播放器仍保留，新增右上方 FPGA 工作台入口。

## 手机使用

1. Android 8.0 及以上安装 `xingzhewujiang-mineradio-v3.apk`。开启蓝牙，授权“附近设备”；Android 8–11 扫描还需要定位权限和系统定位开关。
2. 在“音乐来源”搜索网易云曲名/歌曲链接，点“读取音频”。也可导入普通 MP3/WAV/FLAC，或从音乐 App 分享普通音频文件/网易云歌曲链接到“行者无疆”。可先试听原音。
3. 点“将这首歌转为 FPGA 曲谱”，选择范围（建议先用前 30 秒），开始识别，试听识别结果。
4. 自动识别曲谱不能直接冒充准确谱。确认旋律整理后，选段内同一时刻只保留最强音，折回硬件音域，限制音长与力度，生成可上传的独立曲谱；原识别结果保留。最多 255 音符，超出时缩短选段，不会静默截断。
5. 在工作台连接 BLE，选择“行者无疆”，先检查 FPGA 能力，再上传。显示整曲 CRC 确认后点播放；停止必须收到设备 ACK。仅显示蓝牙已连接不代表 FPGA 已就绪。
6. 曲谱库保存在本机，可导出 JSON/MIDI/协议备份。安装后保留 App 数据；卸载会清除库。若本地服务端口被占用而更换，工作台来源也会改变，应以导出文件备份重要曲谱。

这是“音频转音符后由 FPGA 自身音色重奏”，不是上传或还原 MP3 原声。复杂人声/伴奏识别可能不准确，需选段并试听。默认 NUS 服务 `6e400001-b5a3-f393-e0a9-e50e24dcca9e`，写入 0002、通知 0003。

本版网易云接入支持公开可读取歌曲的搜索、详情和音频读取，不包含账号登录/会员授权曲库；仅试听或未开放普通音频的曲目会报错，不会伪装整曲。NCM、QMC 等平台专属加密文件不支持。上游 Windows 中的 QQ/酷狗/汽水账号功能并未移植到 Android。

## 源码与构建

- Android：`android/app/src/main/java/cn/xingzhewujiang/mineradio`。
- Android 页面与 Windows 入口：`public/mobile.html`、`public/fpga/`。
- 共用上位机：相邻目录 `../instrument-web`；保留编译器、MIDI、曲谱库、协议、上传和播放控制。
- 上游基线：`https://github.com/XxHuberrr/Mineradio-paused`，`d43de565acabfdc1a9c9820a27e81a98ccbebcef`。

构建工具：Node.js 24、PowerShell 7、JDK 17、Android SDK platform 34 / build-tools 34.0.0。不需要 Gradle/Electron 构建 Android。

官方工具下载与本工程默认解压目录（相对仓库根）：

| 官方文件 | 解压目录 |
| --- | --- |
| https://aka.ms/download-jdk/microsoft-jdk-17-windows-x64.zip | `work/android_toolchain_20261020/jdk/jdk-17.0.20.1+1` |
| https://dl.google.com/android/repository/build-tools_r34-windows.zip | `work/android_toolchain_20261020/build-tools/android-14` |
| https://dl.google.com/android/repository/platform-34-ext7_r03.zip | `work/android_toolchain_20261020/platform/android-34` |

若 JDK 归档版本更新，修改 `android/build.ps1` 的 `$jdk` 路径。将源码包解压后保持 `host/mineradio` 与 `host/instrument-web` 相邻。

```powershell
cd host/instrument-web
npm ci
cd ../mineradio
npm run build:android
```

脚本先检查语法和运行完整 Node 回归，再打包离线模型/运行库，最后使用 aapt2、javac、d8、zipalign、apksigner 构建 APK。输出 `android/build/xingzhewujiang-mineradio-v3.apk`。本地演示签名保存在 `android/signing/demo.keystore`，源码包不带私钥；重建会生成不同签名，如需覆盖安装必须保留原签名，不能直接覆盖已有不同签名版本。

```powershell
# 真实模型/MP3 与页面联调；BLE/GATT 和 FPGA 回应是明确的模拟
npm run test:app
# 共用上位机参考 MP3 生成与真实识别验证
cd ../instrument-web
npm run test:audio
```

`test:app` 需要先运行 `test:audio` 生成参考音频，且本机安装 Microsoft Edge，可用 `CHROME_PATH` 指定 Chromium。Windows 原播放器仍按上游命令安装依赖和启动，其新入口未列入 Android 实机验证。

## 验证边界

已完成 Node 回归、真实 MP3/模型/WASM 转谱、App 页面和模拟原生桥的上传 CRC/播放控制验证，以及 Java 编译、APK 资源路径/签名/对齐检查。电脑端公开网易云接口与完整 MP3 下载已验证。未连接 Android 手机，尚未验证手机安装启动、原生 GATT 与实体 FPGA 的端到端演奏；编译通过不等于这些硬件测试通过。

沿用 GPL-3.0-only，参见 LICENSE / NOTICE.md；附对应源码供修改和重建。
