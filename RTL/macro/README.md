# SingleMacro 两拍 LUT/CSA 集成说明

本目录顶层为 `SingleMacro`，使用完整权重 Pair LUT、W2/W4 入口压缩、固定 CSA 和最终 CPA。代码由实验分支 `6de6b59` 的 `rtl_W8main_handcut` 完整复制后，适配 M1 `main` 的 `7a5065a` 接口；当前版本已移除 DW 专用位和内部 pair mask。来源、固定树约束和本地仿真方法见 [RTL 说明](rtl/README.md)。[原始 V0.2 规格](SingleMacro_SPEC_v0.2.md)保留为历史记录，当前实现以本页为准。

## 文件与编译

按 `rtl/filelist.f` 的顺序编译：

1. `rtl/single_macro_pkg.sv`
2. `rtl/MacroClockGate.sv`
3. `rtl/MacroWeightSRAM.sv`
4. `rtl/MacroMul2x4.sv`
5. `rtl/MacroSliceFusion.sv`
6. `rtl/MacroCompress42.sv`
7. `rtl/MacroFullWeightPairLUT.sv`
8. `rtl/MacroW8MainEntry.sv`
9. `rtl/MacroW8MainTreeCSA.sv`
10. `rtl/MacroW8MainTree.sv`
11. `rtl/MacroW8MainCorrection.sv`
12. `rtl/MacroW8MainOC.sv`
13. `rtl/SingleMacro.sv`

文件清单中的路径相对于本目录。支持 filelist 的工具应从本目录运行，例如：

```text
vlog -sv -f rtl/filelist.f
```

以上仅为 ModelSim 源码编译示例，不执行展开或仿真。默认清单包含依赖 HVT FA/HA 的固定 CSA，完整展开需要对应工艺单元模型。本地无库时使用下文 golden model 流程。旧 `MacroMul2x4`/`MacroSliceFusion` 保留供历史 primitive 检查，当前计算路径不实例化它们。`single_macro_pkg.sv` 完整沿用上游常量及函数，须先于引用它的模块编译。旧 `single_macro_func.sv` 与 `single_macro_check_func.sv` 仍保留，但当前顶层不再 include 它们。

## 集成约定

- 请求在上升沿 n 接受，同时捕获 ACT、读权重或复用已读出的行。固定 CSA 的 correction 输入为零，n+1 捕获每 OC 原有的 37 bit `sum_row_q/carry_row_q/carry_in_q`，同时捕获四个 OC 共享的 4 bit W 模式/符号信息。第二拍按这组模式译码 correction，直接计算 `sum_row_q + carry_row_q + correction + carry_in_q`。四路 signed18 Phase Sum、phase、OC mask 和 valid 在 n+2 沿后一起可见。可每拍发射一个 phase（II=1），下游上升沿寄存器在 n+3 采样。CSA 数据及新增模式寄存器不复位，由 valid/control 取消复位前的在途请求。不新增 18 bit correction 数据寄存器。
- `reset_n` 低有效、异步拉低有效；释放须由集成端同步并满足恢复/移除时序。SRAM 内容不复位，Hold-valid 复位。
- `reset_n` 仅连接有复位状态的子模块，不参与请求、ICG 使能或 SRAM 使能的组合译码。`MacroWeightSRAM` 是无复位 wrapper，阵列和读出保持值均不清零。复位期间上层必须将 `cim_ren`、`sram_wen`、`sram_ren` 置0；wrapper 不会自动阻止使能有效时的读写。
- `cim_station=1` 在输入沿读取SRAM；0复用SRAM保持输出，不配置独立held_weight数据寄存器。仅保存行号和有效位，支持紧邻刷新后的复用。
- 零 OC mask 不发射。输出无 ready，Cluster 须提前预留接收位置。最后请求 n 后最早 n+2 写；最后写 w 后最早 w+1 发射刷新计算。
- `USE_CLOCK_GATING` 默认 1，仿真使用功能 ICG 模型，`SYNTHESIS` 分支沿用上游 HVT `CKLNQD8BWP30P140HVT`；置 0 使用普通时钟和寄存器使能。四个 OC 的 CSA 与结果分别门控。
- `MacroWeightSRAM` 是无复位、上升沿按 32 B OC 掩码写、使能同步读的通用存储描述；计算读和紧邻的权重复用共用其保持输出。综合时可将其替换为 `rtl/blackbox/MacroWeightSRAM.sv`，两者不得同时编译。

仿真时定义 `SINGLE_MACRO_ASSERTIONS` 可启用协议检查；定义 `SYNTHESIS` 排除仿真检查器。本次集成的固定树门级仿真、综合和 STA 暂不进行，上游归档的 PPA 不代表适配后的结果。

## 无工艺库的 golden model 仿真

`tb/models/MacroW8MainTreeCSA_golden.sv` 提供与固定 CSA 相同的模块和端口。它按四个 ACT bit-plane 的位权累加 64 个 unsigned9 query row，再加一次 correction，并对 18 bit 取模。输出使用 `sum_row=total, carry_row=0, carry_in=0` 的规范形式，不承诺与固定树每条内部 carry-save row 相同。真实 CSA 寄存器、CPA、LUT、精度译码和 ICG 仍在仿真路径中。

当前 golden 实例的 correction 同样接零，实际修正量在真实第二拍路径中计算并相加。TB 检查固定/golden 输入恒零、共享模式捕获及保持、数学公式得到的修正量，以及精度、符号和 phase 逐拍切换的 II=1 序列。

从仓库根目录运行现有 ModelSim 回归，显式替换固定 CSA 文件：

```sh
python RTL/cluster/tb/py/run_sram_regression.py --csa-golden --full
```

也可用重复的 `--case` 选择 `macro_gate0`、`macro_gate1`、`dw_k256_w2`、`dw_k256_w4`、`dw_k256_w8` 等现有用例。默认 RTL/VCS 编译清单始终选择固定树。golden 文件仅用于测试，不加入生产清单，也不能与固定文件一起编译。本流程验证功能及接口时序，固定门连接、carry-save 具体表示、工艺延迟和 PPA 仍待工艺库验证。

历史记录（删除 DW 专用逻辑前）：2026-11-16，correction 改为第二拍共享译码后的完整 ModelSim golden 回归通过 116 个用例，其中 84 个为预期协议/容量拒绝。门控开、关各核对 2,561 笔 Macro 结果及 3 笔复位取消请求，包含 64 笔有符号普通/DW 逐拍交替。七组 GEMM 的 1,504 个 signed32 结果全部匹配。固定 CSA 与上游 Git 对象逐字一致，功能与 `SYNTHESIS` 预处理分支源码编译通过；未展开或仿真固定门级树，也未进行逻辑综合或 STA。


## 常规 SRAM 访问扩展

SingleMacro 提供 sram_wmask[3:0]、sram_ren、sram_raddr[7:0] 和 sram_rdata[1023:0]；外部实例必须连接这些端口。sram_wmask[c]=1 保持 OC c 的 32 B，=0 写入；全行写入使用 0000。sram_ren 使用现有 SRAM 读路径，不含并发读端口，禁止与计算或写入重叠。有效写入清输出行valid，全屏蔽写保持状态；常规读更新实际输出行号及valid，随后可复用同地址，其他地址须刷新；上层物理 SRAM 时序仍待冻结。详见 [Cluster 常规权重 SRAM 规格](../../docs/Cluster_Weight_SRAM_Interface.md)。

每个 primitive、写行、计算 phase、复位及负向 case 开始打印 CASE_START、仿真时间 ns 和描述；随机计算包含精度、符号、phase、mask、行号和刷新/复用参数。

## TB 文件拆分

顶层 tb/tb_SingleMacro.sv 只保留实例和共享状态；tb/include/ 分为 reference、driver、scoreboard、negative_cases、regression 五个文件。场景顺序在 macro_regression.svh，非法输入集中在 macro_negative_cases.svh。详见 [Testbench 阅读指南](../../docs/Testbench_Guide.md)。从 macro 目录编译 tb/filelist.f；.svh 仅 include，不单独加入编译列表。

Cluster通过`cim_result_mask[3:0]`提供每OC的上层消费需求。该信号随请求寄存，分别控制 n+1 的 CSA 捕获和 n+2 的结果时钟；被祖先mask屏蔽的OC在这两个边界均保持原值。本地issue、valid/phase/OC元数据和Hold行为保持原定义，未请求OC的数据不可消费。单Macro实例将此输入接4'hf。

ACT 寄存器分为 [127:0]、[255:128]、[511:256] 三个 bank。所有请求按 W2/W4/W8 分别捕获 512/256/128 bit，完整处理 128/64/32 个 ACT digit。未用 bank 保持旧值，新精度所需 bank 在该次 issue 沿重新捕获。所有 16 个 physical pair 使用 OC 级 enable，不再有 DW 专用 pair mask。共享 correction 按完整逻辑 pair 数 64/32/16 译码，不再缩放。SingleMacro 的 `cim_dw_compact` 端口已删除；DW 的 K=256 映射完全由 Cluster 的 ACT slot、OC、split 和 enable mask 配置。

权重直接取SRAM的保持输出；独立held_weight及其时钟域、read_address_in和station_in寄存状态不实例化。SRAM行为模型的读出保持仍存在，物理IP需提供等价输出保持。同步读请求仍在 ACT 输入沿采样。

Macro 的函数组织沿用上游 package。Cluster 的综合与仿真检查函数仍通过模块内 include 分离，检查函数位于 tb/cluster_check_func.sv，并受 `ifndef SYNTHESIS` 保护。旧 Macro 函数 include 文件保留供历史版本使用，不重复导入当前顶层。
