# W8main handcut：CSA 输出寄存的两拍实现

本目录为生产 SingleMacro RTL，包含 W2/W4 共用末级 4:2 压缩器，以及固定 FA/HA main tree CSA。

2026-11-16 从[实验分支提交 6de6b59](https://github.com/EvCong24601/Anker-CIM-Block/tree/6de6b5960a26ad06f58c09a43fe03705252a8c8a/SingleMacro_v1.1/W8main_handcut_CSA_2cycle/rtl_W8main_handcut)完整复制全部 17 个文件后，适配 M1 `main` 的 `7a5065a`。生产 SystemVerilog 中仅 `SingleMacro.sv`、`MacroW8MainOC.sv`、`MacroW8MainCorrection.sv` 和 `MacroW8MainTree.sv` 有复位、接口及 correction 流水位置适配，其余上游 SystemVerilog 文件保持逐字一致。固定 `MacroW8MainTreeCSA.sv`、两个 CSA Tcl、函数 package 和无复位 SRAM 均保持原样。

## 数据流与时序

```text
n：接受 ACT 和控制，必要时刷新 SRAM 权重
  → 权重预计算 LUT → W2/W4 局部压缩（W8 旁路）→ 固定 CSA（correction=0）
n+1：每 OC 寄存 sum_row[17:0]、carry_row[17:0]、carry_in
     四个 OC 共享寄存 W 模式 2 bit、权重符号、ACT digit 符号
  → 根据共享 4 bit 模式译码 correction
  → CPA：sum_row_q + carry_row_q + correction + {17'b0, carry_in_q}
n+2：原输出寄存器输出 signed18 数据及 valid/mask/phase
```

各精度均为 `PIPE_LATENCY=2`，II=1。carry_row 已按位权对齐，不再次左移。固定 CSA 的 correction 端口接零，correction 仅在第二拍相加一次，RTL 直接写加法表达式，不指定额外 3:2 结构。
每 OC 的 CSA 数据寄存器仍为 37 bit，四个 OC 共 148 bit。只新增一组共享的 4 bit 模式寄存器，合计 152 bit；不存 18 bit correction 数据。以上为这部分 RTL 声明位数，实际 DFF 数量由综合决定。CSA 数据和新增模式寄存器均无复位，valid 和控制标记负责取消复位前在途请求。
CSA 捕获和输出捕获分别受对应流水级的 valid、OC mask 和 result mask 控制。
共享模式仅在 `in_valid && |(mask_in & result_mask_in)` 时更新，CPA correction 按 n+1 对齐后的结果级使能分发给 OC，不能使用下一笔输入的精度或符号标志。
RTL 共 13 个 ICG：主时钟 1、SRAM 1、ACT 3、CSA 4、结果 4；综合允许优化这些结构。

## 文件与综合入口

- [MacroW8MainTreeCSA.sv](MacroW8MainTreeCSA.sv)：已抽取的固定 CSA，包含 558 个 FA、5 个 HA，绑定 HVT 标准单元。
- [MacroW8MainTree.sv](MacroW8MainTree.sv)：CSA correction 接零、原 37 bit 输出寄存及最终 CPA。修正量在此与两条寄存行直接相加。
- [preserve_csa.tcl](preserve_csa.tcl)：保护 CSA，保留 CPA 的优化空间。
- [check_csa.tcl](check_csa.tcl)：沿用上游脚本，检查 SingleMacro 的四个 CSA 核心的单元类型、数量和保护属性。
- [MacroWeightSRAM.sv](MacroWeightSRAM.sv)：无复位功能 SRAM，使用同步读出保持进行刷新/复用。综合可替换为 [blackbox/MacroWeightSRAM.sv](blackbox/MacroWeightSRAM.sv)，不能同时编译两个定义。
- [filelist.f](filelist.f)：从 `RTL/macro/` 使用 `-f rtl/filelist.f`。默认选用固定 CSA，依赖 `FA1D1BWP30P140HVT` 和 `HA1D1BWP30P140HVT`；ICG 的 `SYNTHESIS` 分支沿用 `CKLNQD8BWP30P140HVT`。

本目录保留 CSA 保护/结构检查 Tcl。上游完整综合入口和历史 PPA 位于实验分支归档中，本次未将报告、数据库、SAIF、门级 TB 等归档产物接入 M1。适配后的综合、STA 和固定门级仿真均待后续完成。

## K=256 DW 映射

SingleMacro 使用完整的 256 bit/OC 权重行，W2/W4/W8 分别处理 128/64/32 个 ACT digit，ACT bank 捕获使能分别为 `111/011/001`。所有 16 个 physical pair 由 OC enable 控制，无 DW 专用 pair mask、模式寄存器或 correction 缩放。完整逻辑 pair 数为 64/32/16，修正量在第二拍按精度及符号译码。

Cluster 的 K=256 映射分别启用 2/4/8 个 Macro，按 ACT slot 路由完整槽，通过 OC、split 和 enable mask 控制参与计算、独立输出或归约。命令恢复 102 bit，SingleMacro 不再含 `cim_dw_compact` 端口。

## 本地无库仿真

[CSA golden model](../tb/models/MacroW8MainTreeCSA_golden.sv)按输入的数学契约计算
`correction + sum(query_row[plane][row] * 2**plane)`，保留低 18 bit。模型与固定树端口一致，用规范形式 `sum_row=total, carry_row=0, carry_in=0` 返回结果。它只保证三项之和，不保证固定树各条 carry-save row 的位图、门连接、延迟或切换活动。

当前实例对 golden 的 correction 端口同样接零，因此 golden 只压缩 query row，实际修正量由真实第二拍译码/CPA 路径加入。TB 检查此端口恒零，并以独立整数点积检查结果。额外检查共享模式捕获/保持、由数学公式推导的 correction，以及 64 笔精度、符号和 phase 逐拍变化的请求，覆盖全部七精度和合法 phase。

从仓库根目录运行：

```sh
python RTL/cluster/tb/py/run_sram_regression.py --csa-golden --full
```

`--csa-golden` 在解析现有编译清单时替换固定 CSA 源文件，不改变生产 RTL，snapshot 的 `sources.json` 和 `summary.log` 记录所用模型。LUT、入口压缩、CSA 寄存边界、CPA、控制和实际 ICG 模型仍参与测试。默认清单与省略该选项的回归继续使用固定树，完整展开/仿真需要工艺模型。固定树与 golden 不能同时编入同一个仿真库。
