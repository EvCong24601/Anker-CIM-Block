# W8main handcut：CSA 输出寄存的两拍实现

本目录为生产 SingleMacro RTL，包含 W2/W4 共用末级 4:2 压缩器，以及固定 FA/HA main tree CSA。

## 数据流与时序

```text
n：接受 ACT 和控制，必要时刷新 SRAM 权重
  → 权重预计算 LUT → W2/W4 局部压缩（W8 旁路）→ 固定 CSA
n+1：寄存 sum_row[17:0]、carry_row[17:0]、carry_in
  → CPA：sum_row_q + carry_row_q + {17'b0, carry_in_q}
n+2：原输出寄存器输出 signed18 数据及 valid/mask/phase
```

各精度均为 `PIPE_LATENCY=2`，II=1。carry_row 已按位权对齐，不再次左移；correction 已进入 CSA，不重复相加。
每 OC 的 CSA 数据寄存器合计 37 bit，无复位；valid 和控制标记负责取消复位前在途请求。
CSA 捕获和输出捕获分别受对应流水级的 valid、OC mask 和 result mask 控制。
RTL 共 13 个 ICG：主时钟 1、SRAM 1、ACT 3、CSA 4、结果 4；综合允许优化这些结构。

## 文件与综合入口

- [MacroW8MainTreeCSA.sv](MacroW8MainTreeCSA.sv)：已抽取的固定 CSA，包含 558 个 FA、5 个 HA，绑定 HVT 标准单元。
- [MacroW8MainTree.sv](MacroW8MainTree.sv)：CSA 输出寄存及最终 CPA。
- [preserve_csa.tcl](preserve_csa.tcl)：保护 CSA，保留 CPA 的优化空间。
- [check_csa.tcl](check_csa.tcl)：检查四个 CSA 的单元类型、数量和保护属性。
- [MacroWeightSRAM.sv](MacroWeightSRAM.sv)：功能 SRAM；综合入口使用 [syn 下的黑盒](../syn/blackbox/MacroWeightSRAM.sv)。
- [filelist.f](filelist.f)：从本归档根目录使用 `-f rtl_W8main_handcut/filelist.f`；固定单元的仿真模型由工艺环境提供。

从归档根目录运行综合：

```sh
cd syn
dc_shell-xg-t -f dc_SingleMacro_hvt_W8main_handcut_3ns.tcl
```

综合脚本位于 [../syn/](../syn/dc_SingleMacro_hvt_W8main_handcut_3ns.tcl)，本 RTL 目录不再包含同名副本。
当前包保留门级 [Toggle TB](../tb/tb_WeightStationary2cycle_Toggle.sv) 和
[Sparsity TB](../tb/tb_WeightStationary2cycle_Sparsity.sv)。
旧 Python 回归驱动、行为参考 TB 和原提取清单已不在本包中；当前文件校验见
[ARCHIVE_MANIFEST.json](../ARCHIVE_MANIFEST.json)，整体目录和实验结果见 [归档说明](../README.md)。
