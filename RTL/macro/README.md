# SingleMacro V0.2 交付说明

本目录为最小 RTL 集成交付包，顶层为 `SingleMacro`。本页说明当前两拍行为接口，端口定义可参阅[原始 V0.2 规格](SingleMacro_SPEC_v0.2.md)第 3、14 节。

## 文件与编译

按 `rtl/filelist.f` 的顺序编译：

1. `rtl/single_macro_pkg.sv`
2. `rtl/MacroClockGate.sv`
3. `rtl/MacroWeightSRAM.sv`
4. `rtl/MacroMul2x4.sv`
5. `rtl/MacroSliceFusion.sv`
6. `rtl/SingleMacro.sv`

文件清单中的路径相对于本目录。支持 filelist 的工具应从本目录运行，例如：

```text
iverilog -g2012 -DSYNTHESIS -s SingleMacro -o singlemacro.vvp -f rtl/filelist.f
```

以上为 RTL 编译/展开示例，不代表完成逻辑综合。SystemVerilog package 只保留常量，须先于引用它的模块编译。辅助函数位于 `rtl/single_macro_func.sv`，在 `SingleMacro` 模块内 include，不单独编译；`rtl/filelist.f` 已配置对应 include 搜索路径。

## 集成约定

- 请求在上升沿 n 接受，同时捕获 ACT、读权重或复用已读出的行。行为模型在 n+1 暂存局部和及标签，四路 signed18 Phase Sum、phase、OC mask 和 valid 在 n+2 沿后一起可见。可每拍发射一个 phase（II=1），下游上升沿寄存器在 n+3 采样。中间寄存位置只用于表达两拍接口延迟，物理 Macro 的算术切分在独立仓库实现。
- `reset_n` 低有效、异步拉低有效；释放须由集成端同步并满足恢复/移除时序。SRAM 内容不复位，Hold-valid 复位。
- `reset_n` 仅连接有复位状态的子模块，不参与请求、ICG 使能或 SRAM 使能的组合译码。`MacroWeightSRAM` 是无复位 wrapper，阵列和读出保持值均不清零。复位期间上层必须将 `cim_ren`、`sram_wen`、`sram_ren` 置0；wrapper 不会自动阻止使能有效时的读写。
- `cim_station=1` 在输入沿读取SRAM；0复用SRAM保持输出，不配置独立held_weight数据寄存器。仅保存行号和有效位，支持紧邻刷新后的复用。
- 零 OC mask 不发射。输出无 ready，Cluster 须提前预留接收位置。最后请求 n 后最早 n+2 写；最后写 w 后最早 w+1 发射刷新计算。
- `USE_CLOCK_GATING` 默认 1，使用功能 ICG 模型；置 0 使用普通时钟和寄存器使能。
- `MacroWeightSRAM` 是无复位、上升沿按 32 B OC 掩码写、使能同步读的通用存储描述；计算读和紧邻的权重复用共用其保持输出。`MacroClockGate` 在 ASIC 流程中需适配工艺 ICG。

仿真时定义 `SINGLE_MACRO_ASSERTIONS` 可启用协议检查；定义 `SYNTHESIS` 排除仿真检查器。接口已通过门控开/关功能回归（每种门控配置各检查 2,498 笔结果和 3 笔被复位取消的请求）及 15 类协议负向检查；尚未进行逻辑综合、门级仿真或 STA。


## 常规 SRAM 访问扩展

SingleMacro 提供 sram_wmask[3:0]、sram_ren、sram_raddr[7:0] 和 sram_rdata[1023:0]；外部实例必须连接这些端口。sram_wmask[c]=1 保持 OC c 的 32 B，=0 写入；全行写入使用 0000。sram_ren 使用现有 SRAM 读路径，不含并发读端口，禁止与计算或写入重叠。有效写入清输出行valid，全屏蔽写保持状态；常规读更新实际输出行号及valid，随后可复用同地址，其他地址须刷新；上层物理 SRAM 时序仍待冻结。详见 [Cluster 常规权重 SRAM 规格](../../docs/Cluster_Weight_SRAM_Interface.md)。

每个 primitive、写行、计算 phase、复位及负向 case 开始打印 CASE_START、仿真时间 ns 和描述；随机计算包含精度、符号、phase、mask、行号和刷新/复用参数。

## TB 文件拆分

顶层 tb/tb_SingleMacro.sv 只保留实例和共享状态；tb/include/ 分为 reference、driver、scoreboard、negative_cases、regression 五个文件。场景顺序在 macro_regression.svh，非法输入集中在 macro_negative_cases.svh。详见 [Testbench 阅读指南](../../docs/Testbench_Guide.md)。从 macro 目录编译 tb/filelist.f；.svh 仅 include，不单独加入编译列表。

Cluster通过`cim_result_mask[3:0]`提供每OC的上层消费需求。该信号随请求寄存并对齐到 n+2 的结果时钟；被祖先mask屏蔽的OC结果保持原值。本地issue、valid/phase/OC元数据和Hold行为保持原定义，未请求OC的数据不可消费。单Macro实例将此输入接4'hf。

ACT 寄存器分为 [127:0]、[255:128]、[511:256] 三个 bank。普通请求按 W2/W4/W8 分别捕获 512/256/128 bit。紧凑 DW 请求从第一次 issue 起只捕获低 128 bit，高两个 bank 保持原值。与该次 issue 同沿寄存的 DW 标志控制参与点积的 Slice，W2 取 0～7，W4 取 0～15，W8 取 0～31。切回普通请求时，所需 bank 在该次 issue 沿重新捕获。独立实例可将新增末端口 `cim_dw_compact` 接 0 以使用普通模式，其默认值为 0。

权重直接取SRAM的保持输出；独立held_weight及其时钟域、read_address_in和station_in寄存状态不实例化。SRAM行为模型的读出保持仍存在，物理IP需提供等价输出保持。同步读请求仍在 ACT 输入沿采样。

仿真专用函数与综合函数分离：综合函数保留在 rtl/*_func.sv；检查和参考计算函数位于 tb/cluster_check_func.sv（Cluster）与 tb/single_macro_check_func.sv（Macro）。RTL 中对检查函数的 include 均受 `ifndef SYNTHESIS 保护，Macro 还要求 SINGLE_MACRO_ASSERTIONS；定义 SYNTHESIS 后无需读取这些 TB 文件。函数文件均通过模块内 include 使用，不单独编译。
