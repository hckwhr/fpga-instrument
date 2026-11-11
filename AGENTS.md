# 仓库约定

FPGA、上位机与 ESP32 整理在此单仓库。2026-11-11 用户明确要求归档当前项目、更新 GitHub 并整理简历材料；当日核实远端 hckwhr/fpga-instrument 已公开，默认分支 main，本任务保持可见性。提交前审核显式路径和敏感信息，不向组件上游推送、不改写历史、不擅自切换可见性。后续同步以用户当次指令为准，执行依据见 CONTRIBUTING.md。

保留当前已验收 RTL、时钟/CDC 与引脚配置。改动按对应组件测试；编译、仿真、P&R 和实物验证分别报告。烧录属于另一个动作，当前整理/上传任务不操作硬件。

FPGA 烧录前阅读 docs/PROGRAMMING.md；脚本默认路径可能不适用于新机器，使用 docs/BUILD.md 的当前入口。最新源码入口为 fpga/rhythm/v3_hdmi_top.gprj，验收见该目录 VALIDATION.md；163 项回归、STA 通过，尚未烧录。fpga/playability 为保留的早期已上板基线，不代表最新板上程序。不要混用两套工程的源码、网表和约束。
