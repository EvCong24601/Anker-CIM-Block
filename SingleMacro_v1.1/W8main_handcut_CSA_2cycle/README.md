# W8main handcut CSA：两拍 RTL 与实验结果

该版本将 main tree 中的固定 FA/HA CSA 输出寄存，再由 CPA 求和，计算延迟为两拍，II=1。
支持 W2/W4/W8 和各 ACT 精度。综合目标为 3 ns；本目录保存的 VCS 功耗实验采用 3.906 ns。

## 当前目录

| 路径 | 内容 |
|---|---|
| [rtl_W8main_handcut/](rtl_W8main_handcut/) | 生产 RTL、功能 SRAM、黑盒、编译清单、CSA 保护与检查脚本 |
| [syn/dc_SingleMacro_hvt_W8main_handcut_3ns.tcl](syn/dc_SingleMacro_hvt_W8main_handcut_3ns.tcl) | 3 ns HVT 综合脚本，引用相邻 RTL 目录 |
| [syn/blackbox/MacroWeightSRAM.sv](syn/blackbox/MacroWeightSRAM.sv) | 综合脚本使用的 SRAM 黑盒 |
| [syn/syn_files/](syn/syn_files/) | `20261113_221702_333MHz_22nmHVT_TT_W8main_handcut`：网表、SDF、SDC、DB、DDC，共 5 个文件 |
| [syn/reports/](syn/reports/) | 同批次的 12 个综合报告 |
| [tb/](tb/) | Toggle / Sparsity 两个门级 TB 及参数说明 |
| [build/ws32_toggle/](build/ws32_toggle/) | WS=32、翻转率 5/10/20/50%：每组 SAIF、sim.log、空 ucli.key |
| [build/ws32_sparsity/](build/ws32_sparsity/) | WS=32、稀疏度 50/70/90/100%：每组 SAIF、sim.log、空 ucli.key |
| [ptpx/](ptpx/) | 12 组 PTPX 结果，每组 6 个报告 |
| [ARCHIVE_MANIFEST.json](ARCHIVE_MANIFEST.json) | 当前文件路径、大小、SHA-256 和已有来源记录；不包含清单自身 |

当前保留 8 组 VCS 结果，8 份 sim.log 均包含 PASS。
PTPX 包含与其对应的 8 组报告，以及普通 WS=2/8/16/32 的 4 组报告。
普通 WS 的原始仿真目录 `build/ws_256_handcut_2cycle/` 已按用户要求排除，PTPX 报告仍保留。
本包保留当前人工筛选后的结构，没有恢复已删除的回归 TB、批量实验脚本或旧清单。

## 综合

从本目录执行：

```sh
cd syn
dc_shell-xg-t -f dc_SingleMacro_hvt_W8main_handcut_3ns.tcl
```

脚本自行切换到其所在目录，从 `../rtl_W8main_handcut/` 读取 RTL，
并加载其中的 `check_csa.tcl`、`preserve_csa.tcl`。
后者保护四个 CSA；前者检查每个 CSA 中 558 个 FA、5 个 HA 及 dont_touch 属性。
CPA 和新增数据寄存器仍参与综合优化。
标准单元库路径由脚本中的 `NVLM_PATH`、`STD_DB` 指定，需要匹配实际工艺环境。

脚本新运行的输出为 `syn/reports_SingleMacro/<时间戳>_333MHz_22nmHVT_TT_W8main_handcut/`
和 `syn/syn_files_SingleMacro/<时间戳>_333MHz_22nmHVT_TT_W8main_handcut/`；
本包中的历史结果则分别存于 `syn/reports/` 和 `syn/syn_files/`。

## 门级仿真与功耗

两个 TB 的顶层都为 `tb_WeightStationaryNetlist`，DUT 实例为 `dut`，编译时选择一个。
参数及运行示例见 [Toggle 说明](tb/TOGGLE_CONTROL.md) 和 [Sparsity 说明](tb/SPARSITY_CONTROL.md)。

两个 TB 均保留 `build/sdf/SingleMacro.handcut.sim.v` 的 include，以及 `SDF_FILE` 编译宏。
路径相对于实际仿真工作目录；运行前需要准备对应网表和标准单元/SRAM 功能模型。
综合输出原件 `SingleMacro.syn.v` 与服务器使用的 `SingleMacro.handcut.sim.v` 应区分，
归档没有自动重建仿真用网表或删除黑盒 stub。所有输入在下降沿驱动，输出按 TB 的采样延迟检查。

SAIF 的测量窗口包括连续发射和流水排空，不含 SRAM 初始化；原日志保留服务器绝对路径和命令，
这些路径是历史记录，不要求它们在当前仓库中存在。
SRAM 阵列使用黑盒综合，因此 PTPX 报告中的计算逻辑功耗不包含 SRAM 阵列功耗。
独立 VCS 编译驱动、PTPX Tcl 和工艺库不在本目录中。

## 文件清单与保存方式

`ARCHIVE_MANIFEST.json` 按当前磁盘内容重建，移除不存在的条目，记录迁移后的 `tb/`、`build/`、`ptpx/` 路径。
`archive_sha256` 是当前归档内容的校验值；已有来源文件仍保留 `source`、`source_sha256`。
适配说明和忽略规则的文件标注为已适配，不声称它们仍与原件字节相同。
`.gitattributes` 禁止自动换行转换。

本次仅更新归档说明、忽略规则和清单，没有重新运行综合、VCS 或 PTPX。
当前目录不包含超过 100 MiB 的单文件；先前新增的普通 WS 大波形随对应仿真目录一起移除。
