# 第三版封装与参考资料包

整理日期：2026-10-07。当前正式主控选型是 **ESP32-S3-WROOM-1-N16R8 模组直接贴装**，不是整块开发板。

画板入口：[第三版封装与引脚分配](../第三版封装与引脚分配.md)。采购入口：[第三版采购与队友交接清单](../第三版采购与队友交接清单.md)。

## 主控优先使用的文件

| 文件 | 用途 |
|---|---|
| [ESP32-S3-WROOM-1封装](espressif_ESP32-S3-WROOM-1.kicad_mod) | 乐鑫官方KiCad模组焊盘；N16R8使用此模组外形，符号脚号仍需与手册逐一核对 |
| [ESP32-S3-WROOM-1 STEP](espressif_ESP32-S3-WROOM-1.STEP) | 结构空间检查；不能代替焊盘/天线净空检查 |
| [模组数据手册](esp32-s3-wroom-1_datasheet.pdf) | 引脚定义、外围电路、尺寸和推荐焊盘，本地提取文本亦保留 |
| [乐鑫KiCad完整库快照](espressif_kicad.zip) | 包含符号、封装、3D模型；按实际EDA工具导入 |
| [乐鑫库许可](espressif_LICENSE.md) | 分发与使用时保留 |

来源为乐鑫官方 `espressif/kicad-libraries`，本地快照来自main分支，不声称是固定发行版。下载来源及SHA256见[sources.csv](sources.csv)。单独提取的模组文件来自该ZIP。

封装3D路径使用原库环境变量；若未安装完整库，需在EDA中手动指定本地STEP。嘉立创EDA等工具是否支持直接导入取决于版本；导入或重建后检查焊盘编号、尺寸、阻焊和钢网，不把成功导入等同于可投板。

## 音频与其他参考

- [MAX98357A/B数据手册](max98357a_datasheet.pdf)：本方案只选A版本；注意I2S、SD_MODE声道选择和BTL输出。
- [Adafruit功放参考板ZIP](adafruit_max98357.zip)：单声道板参考 `Adafruit MAX98357 Breakout.brd/.sch`，已解压至adafruit目录。仓库还含Stereo rev B，不能混用。保留其中README与license；它不是所有商家模块的通用封装。
- [SN74AHCT125手册](sn74ahct125_datasheet.pdf)：灯带3.3V到5V缓冲及/OE设计。
- `JST_PH_B2B...`至`JST_PH_B6B...`：2～6针、2.00mm间距连接器参考封装，不能用于未核算的大电流入口。
- `SOIC-14_3.9x8.7mm_P1.27mm`、`SOIC-16_3.9x9.9mm_P1.27mm`、`SOT-23`：标准封装，必须核对实际器件后缀和符号脚序。
- `LED_WS2812B_PLCC4_5.0x5.0mm_P3.2mm`：经典5050参考封装，不能跨WS2812版本直接套用。
- `PinHeader_2x20...`、`PinSocket_2x20...`：2.54mm接口参考，实际J13配合、插接面方向和连接器高度另核对。

标准封装来自KiCad GitHub仓库master快照，许可见[kicad_LICENSE.md](kicad_LICENSE.md)。这不是KiCad 9.0.0发行版；早先尝试的版本下载地址失败，没有作为来源交付。

INMP441厂家旧链接返回网页而非PDF；失败响应保留为 `failed_inmp441_response.html`，不能拿它当手册。尚无已确认的具体INMP441商家小板机械图，因此当前用J_MIC短线接口，不批准其未知直插封装或裸麦克风焊盘。

## 非默认装配资料

- `devkitc1_*`、`espressif_ESP32-S3-DevKitC.kicad_mod`、`PinSocket_1x22...`：此前开发板路线的参考资料，已取消整板插装，不加入当前BOM。
- `espressif_ESP32-C3-MINI-1.*`：独立BLE子板备选，默认不装。主S3自带BLE仍需软件适配。

## 实际检查结果

2026-10-07通过PowerShell进行只读检查：

- 12条S3外设信号的GPIO与模组焊盘均匹配本地官方数据手册及封装，无重复分配，也未使用本方案排除的启动、USB、存储和调试引脚。
- 14个J13信号/预留球位与Dock31005原理图Bank2映射匹配；与stage20 CST对比仅A15/A16是预期的原UART复用。
- sources.csv中21个下载文件的SHA256与现存文件匹配。
- 收集15个`.kicad_mod`文件；检查了焊盘编号数量，其中WROOM-1为41个不同编号、DevKit为44、C3-MINI-1为53。计数检查不等于完整封装几何审核。

未运行原理图ERC、PCB DRC、仿真、固件构建或硬件验证。模组天线净空、最小系统电源、单端掉电隔离及实际采购模块尺寸仍须在生产设计中完成。

本次文档完善后再次检查：4份交接文档的22个本地链接有效，表格列数与代码块闭合检查通过；12条S3 GPIO/模组焊盘映射仍匹配手册且不重复；14个J13信号/预留球位匹配Dock资料，与stage20 CST仅有预期UART复用；12组三灯顺序覆盖软件索引0～35、实物序号1～36，无遗漏。

新增的《第五期-WS2812B灯.rar》只读检查了WS2812B.h/.c：STM32 PB7单路输出、默认9颗、24位GRB逐灯缓存。该归档保留在工程根目录，作为控制原理参考；没有运行其脚本、编译或将STM32代码当作FPGA驱动交付。
