# 后续开发与同步

此仓库是比赛统一交付入口，后续 FPGA、上位机、ESP32 优化均使用同一仓库、同一链接。

1. 首先确认当前 Git 根是本仓库，绝不在 `C:/Users/hck` 用户目录根宽泛暂存。三个组件不是 submodule，不向原上游提交。
2. 修改前检查 status；保留用户已有改动，提交前逐项审阅文件清单和 diff，显式选择路径，不使用 `git add .` 或 `git add -A`。
3. 不提交 Wi-Fi 密码、cookie/token、NVS/设备身份备份、Android 签名私钥、node_modules 或工具链。
4. 根据改动运行测试，更新验收记录。RTL 变更须完整回归、综合、P&R；建立/保持违例 0、setup ≥ +0.03 ns、hold ≥ 0、45 引脚及 3 时钟审计通过后才可交付烧录。
5. 提交使用 Conventional Commits；优化完成后按用户授权推送到本仓库，核对远端 commit 和 private 状态，不 force-push、不自动公开。未验证之处如实说明。

首次由原工作区整理到本仓库，生产 RTL/约束未更改。`SOURCE_MANIFEST.json` 记录原文件快照，少量目录适配变更另见 `docs/PACKAGING.md`。若继续在原工作区开发，须先审阅同步差异再同步本仓库，不能盲目覆盖这里的新增改动。
