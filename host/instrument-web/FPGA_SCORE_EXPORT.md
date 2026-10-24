# MIDI → FPGA 离线曲谱

本工具复用网页 MIDI 解析器，不连接、不上传、不改变网页的设备 ACK 判定。

```powershell
npm run export:fpga -- first.mid 0 second.mid 1 output.v
```

参数依次为槽 0 MIDI、旋律轨索引、槽 1 MIDI、旋律轨索引、输出 Verilog 路径。轨道索引从 0 起，旋律轨必须有音符且为单声部；其它轨全部作为伴奏。输出 `song_timeline_rom` 模块及 `output.v.json` 检查报告，供第十二阶段 `song_timeline` 播放器使用。

限额：每曲 512 个 ON/OFF 事件；C3～B5；同刻 16 个事件；保守含释放尾音最多 16 个占用声部、力度和最多 768；旋律总数最多 255。超出时明确报错，不自动移调、不删轨、不改力度。鼓轨、CC、Program Change、Pitch Bend、Aftertouch、SysEx 和不配对音符均拒绝。

保留 MIDI 速度变化，按绝对时间量化为 6.25 ms。面板 100 档对应原速，每边沿量化误差最多 3.125 ms；其它档按比例播放。输出只是构建输入，须重新构建并烧录。当前 LCD 两槽名称仍为内置曲名，替换作品需同步调整显示名称。

单元测试夹具 `test/fixtures/fpga-scores/` 来自第十二阶段 `tools/create_demo_midi.mjs`，是公版《小星星》《欢乐颂》的简单编配。测试包含独立 ID、速度变化、同刻事件、尾音占用和错误拒绝。

2026-10-20：此工具仍用于生成构建时 ROM；网页另有 SONG2 上传入口，当前 stage59b FPGA 已包含其接收/播放逻辑。运行时上传无需重新构建位流，但曲谱保存在 RAM，断电丢失。使用及实测边界见 [README.md](README.md)。
