# W8main handcut：CSA 输出寄存的两拍实现

本目录为生产 SingleMacro RTL，包含 W2/W4 共用末级 4:2 压缩器，以及采用 HVT 标准单元的固定 main tree CSA。

2026-11-16 从[实验分支提交 6de6b59](https://github.com/EvCong24601/Anker-CIM-Block/tree/6de6b5960a26ad06f58c09a43fe03705252a8c8a/SingleMacro_v1.1/W8main_handcut_CSA_2cycle/rtl_W8main_handcut)完整复制全部 17 个文件后，适配 M1 `main` 的 `7a5065a`。生产 SystemVerilog 中仅 `SingleMacro.sv`、`MacroW8MainOC.sv`、`MacroW8MainCorrection.sv` 和 `MacroW8MainTree.sv` 有复位、接口及 correction 流水位置适配，其余上游 SystemVerilog 文件保持逐字一致。固定 `MacroW8MainTreeCSA.sv`、两个 CSA Tcl、函数 package 和无复位 SRAM 均保持原样。

2026-11-25 更新：CSA 已替换为 `../csa_synth/syn/syn_files_MacroW8MainTreeCSATop/20261125_221631_667MHz_22nmHVT_TT_CSATop/MacroW8MainTreeCSATop.syn.v` 中的组合核心。提取时删除无负载的 correction 端口，去掉四个恒零输出高位，并更新接收接口和结构检查。

## 数据流与时序

```text
n：接受 ACT 和控制，必要时刷新 SRAM 权重
  → 权重预计算 LUT → W2/W4 局部压缩（W8 旁路）→ 固定 CSA
n+1：每 OC 寄存 sum_row[15:0]、carry_row[15:0]、carry_in
     四个 OC 共享寄存 W 模式 2 bit、权重符号、ACT digit 符号
  → 根据共享 4 bit 模式译码 correction
  → CPA：{2'b00, sum_row_q} + {2'b00, carry_row_q} + correction + {17'b0, carry_in_q}
n+2：原输出寄存器输出 signed18 数据及 valid/mask/phase
```

各精度均为 `PIPE_LATENCY=2`，II=1。carry_row 已按位权对齐。固定 CSA 已移除 correction 端口，两条无符号行零扩展至 18 bit 后参与 CPA，correction 在第二拍相加一次。
每 OC 的 CSA 数据寄存器为 33 bit，四个 OC 共 132 bit，加上共享的 4 bit 模式寄存器，合计 136 bit。以上为这部分 RTL 声明位数，实际 DFF 数量由综合决定。CSA 数据和模式寄存器均无复位，valid 和控制标记负责取消复位前在途请求。
CSA 捕获和输出捕获分别受对应流水级的 valid、OC mask 和 result mask 控制。
共享模式仅在 `in_valid && |(mask_in & result_mask_in)` 时更新，CPA correction 按 n+1 对齐后的结果级使能分发给 OC，不能使用下一笔输入的精度或符号标志。
RTL 共 13 个 ICG：主时钟 1、SRAM 1、ACT 3、CSA 4、结果 4；综合允许优化这些结构。

## 文件与综合入口

- [MacroW8MainTreeCSA.sv](MacroW8MainTreeCSA.sv)：已抽取的固定 CSA，包含 543 个 FA、35 个逻辑门，绑定 HVT 标准单元。
- [MacroW8MainTree.sv](MacroW8MainTree.sv)：33 bit CSA 输出寄存及最终 CPA。两条寄存行零扩展后与修正量相加。
- [preserve_csa.tcl](preserve_csa.tcl)：保护 CSA，保留 CPA 的优化空间。
- [check_csa.tcl](check_csa.tcl)：检查 SingleMacro 的四个 CSA 核心的单元类型、数量和保护属性，每个核心共 578 个单元。
- [MacroWeightSRAM.sv](MacroWeightSRAM.sv)：无复位功能 SRAM，使用同步读出保持进行刷新/复用。综合可替换为 [blackbox/MacroWeightSRAM.sv](blackbox/MacroWeightSRAM.sv)，不能同时编译两个定义。
- [filelist.f](filelist.f)：从 `SingleMacro_sramwrap/` 使用 `-f rtl/filelist.f`。CSA 依赖 `check_csa.tcl` 列出的八种 HVT 单元；ICG 的 `SYNTHESIS` 分支使用 `CKLNQD8BWP30P140HVT`。

本目录保留 CSA 保护/结构检查 Tcl。上游完整综合入口和历史 PPA 位于实验分支归档中，本次未将报告、数据库、SAIF、门级 TB 等归档产物接入 M1。适配后的综合、STA 和固定门级仿真均待后续完成。

## K=256 DW 映射

SingleMacro 使用完整的 256 bit/OC 权重行，W2/W4/W8 分别处理 128/64/32 个 ACT digit，ACT bank 捕获使能分别为 `111/011/001`。所有 16 个 physical pair 由 OC enable 控制，无 DW 专用 pair mask、模式寄存器或 correction 缩放。完整逻辑 pair 数为 64/32/16，修正量在第二拍按精度及符号译码。

Cluster 的 K=256 映射分别启用 2/4/8 个 Macro，按 ACT slot 路由完整槽，通过 OC、split 和 enable mask 控制参与计算、独立输出或归约。命令恢复 102 bit，SingleMacro 不再含 `cim_dw_compact` 端口。

## 验证及上游仿真接口

本次通过 9,346 组布尔级检查，包含全零、全一、576 位逐位置一与逐位置零、8,192 组随机输入。缩位后的两条输出行及 carry_in 与原版 correction=0 的输出逐位一致，完整无符号加权和及加入 correction 后的低 18 bit 结果一致。单元布尔函数对照本地同系列 SVT Liberty 核对。HVT 时序、完整 Macro HDL 仿真和形式等价验证仍待执行。

下述记录描述上游原接口的 golden 仿真。复用时需要将 golden 模型和端口检查适配为无 correction、双 16 bit 行接口。所有 query row 的加权和最大为 122640，应拆成两条 16 bit 行及 carry_in，避免把总和直接截断到单条 16 bit 行。

[CSA golden model](../tb/models/MacroW8MainTreeCSA_golden.sv)按输入的数学契约计算
`correction + sum(query_row[plane][row] * 2**plane)`，保留低 18 bit。模型与固定树端口一致，用规范形式 `sum_row=total, carry_row=0, carry_in=0` 返回结果。它只保证三项之和，不保证固定树各条 carry-save row 的位图、门连接、延迟或切换活动。

当前实例对 golden 的 correction 端口同样接零，因此 golden 只压缩 query row，实际修正量由真实第二拍译码/CPA 路径加入。TB 检查此端口恒零，并以独立整数点积检查结果。额外检查共享模式捕获/保持、由数学公式推导的 correction，以及 64 笔精度、符号和 phase 逐拍变化的请求，覆盖全部七精度和合法 phase。

从仓库根目录运行：

```sh
python RTL/cluster/tb/py/run_sram_regression.py --csa-golden --full
```

`--csa-golden` 在解析现有编译清单时替换固定 CSA 源文件，不改变生产 RTL，snapshot 的 `sources.json` 和 `summary.log` 记录所用模型。LUT、入口压缩、CSA 寄存边界、CPA、控制和实际 ICG 模型仍参与测试。默认清单与省略该选项的回归继续使用固定树，完整展开/仿真需要工艺模型。固定树与 golden 不能同时编入同一个仿真库。
