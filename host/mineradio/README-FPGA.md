# FPGAvedio 桌面与 Android 应用

本工程基于 Mineradio 扩展，保留播放器模式，并加入 FPGA 工作台。桌面与 Android 共用播放器页面及 `../instrument-web` 中的转谱、上传、曲谱库和演奏录音逻辑；Android 使用 Java 原生 BLE/GATT 适配。

## 使用流程

1. 在播放器搜索歌曲、登录网易云或导入本地普通音频。平台音频是否可读取取决于账号权限与服务响应，不支持 NCM、QMC 等加密文件。
2. 把当前歌曲送入 FPGA 工作台，或直接导入音频/MIDI。音频经本地识别得到音符，先试听识别结果。
3. 选取演奏范围并生成曲谱，默认保留和弦与延音。使用“试听 FPGA 演奏参考”核对实际准备上传的节奏、力度与音高。
4. 扫描 BLE“行者无疆”，连接并读取设备能力。曲谱上限以板端 CAPS 为准，当前为 4096 个事件，通常对应 2048 个完整音符。
5. 上传完成后单独点击播放；停止须等待 FPGA 应答。蓝牙连接成功或数据发送完成均不代表 FPGA 已执行命令。
6. “我的演奏”支持十二键自定义音高与真实 FPGA 混音录音回传；本地试听图形与板端采样图形分开展示。

歌曲采用识别音符后由 FPGA 自身音色重奏的方式，不传输原始 MP3 声音。曲谱保存在 FPGA RAM，断电丢失。应用内曲谱库可导出备份，卸载应用会清除本地数据。

Android 8.0 及以上可使用原生 BLE；按系统提示授予附近设备权限，Android 8–11 扫描还需要定位权限和定位开关。电脑端支持 USB 手动备用；Android 不支持 Web Serial 时禁用该选项。

## 源码结构

- `public/index.html`：共用播放器入口。
- `public/fpga/`：工作台壳及 Android 页面/原生桥适配。
- `android/app/src/main/java/cn/xingzhewujiang/mineradio/`：Android 生命周期、资源服务、音乐服务和 BLE。
- `tools/prepare-app.mjs`：将共用前端和播放器资源打包到桌面及 Android 资源目录。
- 相邻的 `../instrument-web`：共用业务逻辑，不能省略。

## 构建

安装 Node.js 24、PowerShell 7，并在 `host/instrument-web` 和本目录各执行 `npm ci`。桌面构建入口为 `npm run build:fpga:dir`。详细顺序见 [统一构建说明](../../docs/BUILD.md)。

Android 使用 JDK 17、Android SDK platform 34 / build-tools 34.0.0，通过 `aapt2`、`javac`、`d8`、`zipalign`、`apksigner` 构建，不依赖 Gradle。`android/build.ps1` 中的工具目录需对应本机安装；默认工具目录位于仓库根 `work/android_toolchain_20261020` 下。

```powershell
# 从 host/mineradio 执行
node --test tests/*.test.js
npm run build:android
```

构建脚本准备共用资源并输出 `android/build/FPGAvedio-Android.apk`。本地签名保存在 `android/signing/`，不随源码上传。覆盖已有安装必须使用相同签名，重新生成签名不能直接覆盖旧应用。

播放器派生源为 https://github.com/XxHuberrr/Mineradio-paused ，基线 `d43de565acabfdc1a9c9820a27e81a98ccbebcef`。沿用 GPL-3.0-only，许可证与修改声明见 LICENSE、NOTICE.md。
