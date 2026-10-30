# CIM Cluster RTL

八个 SingleMacro 组成一个 Cluster，完成低比特乘加、归约、跨 Tile 累加及 INT8 量化输出。

## 快速运行

在 **Linux + VCS + GNU Make + Python 3** 环境中运行；查看波形另需 Verdi/FSDB。

```sh
cd vcs-rtl
make list                         # 全部用例及说明
make run CASE=cluster_default     # 基础计算与时序
make gemm-regression              # 13 个正向 GEMM 用例
make regression                   # 全部用例，包含预期报错的负向测试
```

运行结果在 `vcs-rtl/work/<CASE>/`：`compile.log`、`sim.log`、`sim.exit`、`data/` 和波形。使用 `make run` 完成生成、编译、仿真和结果检查；参数及波形操作见 [VCS README](vcs-rtl/README.md)。

## 文件导航

### vcs-rtl：仿真入口

以下文件均在 [`vcs-rtl/`](vcs-rtl/) 下；`.f` 是编译清单。

| 文件 | 用途 |
|---|---|
| [Makefile](vcs-rtl/Makefile) | 运行、编译、回归、检查和波形命令入口 |
| [cases.py](vcs-rtl/cases.py) | 用例配置源，选择 TB、参数、golden 生成器及通过条件 |
| [cases.mk](vcs-rtl/cases.mk) | `python3 cases.py --write` 生成的 Make 配置 |
| [verilog_file_common.f](vcs-rtl/verilog_file_common.f) | 共用功能 RTL，按 package / Macro / Cluster 的依赖顺序编译 |
| [verilog_file_cluster.f](vcs-rtl/verilog_file_cluster.f) | Cluster 顶层功能测试与时延观察器 |
| [verilog_file_macro.f](vcs-rtl/verilog_file_macro.f) | SingleMacro 单元测试 |
| [verilog_file_reduce.f](vcs-rtl/verilog_file_reduce.f) | 归约树单元测试 |
| [verilog_file_requant.f](vcs-rtl/verilog_file_requant.f) | Requant 算术单元测试 |
| [verilog_file_gemm_os1_ws32_w8a16.f](vcs-rtl/verilog_file_gemm_os1_ws32_w8a16.f) | W8A16，OS1 / WS32 / AS1 矩阵测试 |
| [verilog_file_gemm_os2_as4_w8a16.f](vcs-rtl/verilog_file_gemm_os2_as4_w8a16.f) | W8A16，OS2 / WS1 / AS4 矩阵测试 |
| [verilog_file_gemm_os1_ws1_as8_w8a16.f](vcs-rtl/verilog_file_gemm_os1_ws1_as8_w8a16.f) | W8A16，OS1 / WS1 / AS8，门控及 Command 切换 |
| [verilog_file_gemm_w4a16_high_group.f](vcs-rtl/verilog_file_gemm_w4a16_high_group.f) | W4A16 高归约组测试 |
| [verilog_file_gemm_w2a8_high_group.f](vcs-rtl/verilog_file_gemm_w2a8_high_group.f) | W2A8 高归约组测试 |
| [verilog_file_gemm_w4a16_n6_tail.f](vcs-rtl/verilog_file_gemm_w4a16_n6_tail.f) | W4A16，N=6 尾块与掩码测试 |
| [verilog_file_gemm_w4a16_round_clip.f](vcs-rtl/verilog_file_gemm_w4a16_round_clip.f) | W4A16 舍入和饱和测试 |
| [verilog_file_pl.f](vcs-rtl/verilog_file_pl.f) | 兼容聚合清单，当前 Makefile 不使用 |
| [README.md](vcs-rtl/README.md) / [.gitignore](vcs-rtl/.gitignore) | 运行细则与全部 case 表 / 忽略仿真产物 |

### RTL：功能实现

| 文件 | 用途 |
|---|---|
| [macro/rtl/single_macro_pkg.sv](RTL/macro/rtl/single_macro_pkg.sv) | Macro 精度常量 |
| [macro/rtl/single_macro_func.sv](RTL/macro/rtl/single_macro_func.sv) | 模块内 include 的辅助函数 |
| [macro/rtl/SingleMacro.sv](RTL/macro/rtl/SingleMacro.sv) | 单 Macro 顶层，连接权重存储、乘法及 Slice 融合 |
| [macro/rtl/MacroWeightSRAM.sv](RTL/macro/rtl/MacroWeightSRAM.sv) | 权重 SRAM 行存储、读写和 OC 写掩码 |
| [macro/rtl/MacroMul2x4.sv](RTL/macro/rtl/MacroMul2x4.sv) | 2bit 权重 × 4bit 激活的基础乘法 |
| [macro/rtl/MacroSliceFusion.sv](RTL/macro/rtl/MacroSliceFusion.sv) | 按 W2/W4/W8 移位融合权重 Slice 结果 |
| [macro/rtl/MacroClockGate.sv](RTL/macro/rtl/MacroClockGate.sv) | 功能 ICG 时钟门控模型 |
| [cluster/rtl/cluster_pkg.sv](RTL/cluster/rtl/cluster_pkg.sv) | Cluster 命令和 Requant 配置类型 |
| [cluster/rtl/cluster_func.sv](RTL/cluster/rtl/cluster_func.sv) | 模块内 include 的辅助函数 |
| [cluster/rtl/cluster_top.sv](RTL/cluster/rtl/cluster_top.sv) | Cluster 顶层，8 Macro 调度、ACT 缓存、tmp/Psum 和量化输出 |
| [cluster/rtl/ClusterReduceTree.sv](RTL/cluster/rtl/ClusterReduceTree.sv) | 可配置归约树、lane valid 和转发门控 |
| [cluster/rtl/ClusterRequant.sv](RTL/cluster/rtl/ClusterRequant.sv) | 四通道整数 Requant，执行缩放、舍入和 INT8 饱和 |
| [macro/rtl/filelist.f](RTL/macro/rtl/filelist.f) / [cluster/rtl/filelist.f](RTL/cluster/rtl/filelist.f) | 从各自 Macro / Cluster 目录使用的功能源码清单 |
| [macro/tb/](RTL/macro/tb/) / [cluster/tb/](RTL/cluster/tb/) | TB 顶层、驱动、参考模型、检查器、向量和日志 |

TB 顶层与用例见下表；其余 `include/*.svh`、`py/*.py`、数据及说明文件逐项用途见 [辅助文件索引](docs/Source_Map.md)。

### lib：接口与黑盒模型

| 文件 | 用途 |
|---|---|
| [cluster_top.lib](lib/cluster_top.lib) | Cluster 接口 Liberty 模型，用于黑盒链接，未包含时序弧和功耗表征 |
| [blackbox/cluster_top.sv](lib/blackbox/cluster_top.sv) | Cluster 接口空壳，替代功能实现参与黑盒链接 |
| [blackbox/cluster_pkg.sv](lib/blackbox/cluster_pkg.sv) | 随黑盒交付的接口类型 package，须先于空壳编译 |

## 当前功能与使用入口

OS 表示跨 K Tile 累加，WS 表示权重复用多个 Context，AS 表示激活复用多个 Context。

| 功能 | 当前支持范围 | 从哪里看 / 跑 |
|---|---|---|
| 多精度计算 | W2A4、W2A8、W4A4、W4A8、W4A16、W8A8、W8A16 | `cluster_default`；[Macro 规格](RTL/macro/SingleMacro_SPEC_v0.2.md) |
| OS / WS / AS 调度 | count 为 1～511；WS 与 AS 不能同时大于 1；默认深度下 AS≤16，覆盖 OS1/WS64 | `context_stress`；[调度与容量](docs/Cluster_Input_Overlap.md) |
| 输入与计算重叠 | 当前 ACT Plane / Context 地址就绪即可内部发射 | `input_overlap`；[输入时序](docs/Cluster_Input_Overlap.md) |
| 常规权重 SRAM | 行读写、32 B OC 写掩码、同步读响应、Macro 编号锁存 | `sram_rw`、`sram_response`；[SRAM 接口](docs/Cluster_Weight_SRAM_Interface.md) |
| INT8 Requant | per-tensor / per-channel scale；四个本地 OC 固定映射；INT10 shift | `requant_unit`、`requant_channel`；[量化说明](docs/Cluster_Requant.md) |
| Context 缓存 | Psum、地址及量化表默认深度 16，由 `OUTPUT_PSUM_DEPTH` 联动 | `requant_buffers`、`requant_a4_address_bypass` |
| 时钟门控 | Macro、ACT 分区、归约、Context 表及输出；门控开关逐拍等价检查 | `gate_equiv_*`；[ACT 门控](docs/Cluster_ACT_Gating.md) |
| GEMM 端到端 | 13 个正向矩阵，覆盖复用、高组、尾块、舍入与饱和 | `make gemm-regression`；[GEMM 说明](docs/Cluster_GEMM.md) |

正式结果为 `requant_data_o` / `requant_valid_o`，每拍最多 4 个有效 OC，无输出反压；INT8 比内部 raw 晚 1T。per-tensor 的逐 channel ZP 修正在 TB 完成，per-channel 在 DUT 内加 ZP，详见量化说明。raw signed32 仅供 TB 观察，中间累加需满足 signed32 范围。

**Requant 实现状态**：[`ClusterRequant.sv`](RTL/cluster/rtl/ClusterRequant.sv) 内部为纯组合逻辑，没有时钟、数据寄存器或算术流水；乘法、可变移位、舍入、加 ZP 和饱和处于同一组合路径。INT8 输出寄存器位于 `cluster_top`，使输出比 raw 晚 1T。普通范围仍使用组合可变移位；大 shift 已有精确阈值简化（`shift≥32` 或 `shift≤−64`），因此不能称为完全没有移位优化。当前未完成面向目标工艺的综合、STA 及面积验证，组合路径是否满足目标频率仍需确认。

## TB 与用例

以下 `CASE` 均可用 `make run CASE=<名称>` 执行。`{tensor,channel}` 表示两个独立用例后缀；`*` 表示一组用例，完整名字用 `make list` 查看。

| TB 源文件（相对 RTL/） | CASE / 用例组 | 检查内容 |
|---|---|---|
| [macro/tb/tb_SingleMacro.sv](RTL/macro/tb/tb_SingleMacro.sv) | `macro_gate0`、`macro_gate1`、`macro_negative_*` | Macro 算术、门控开关及 15 类协议负向测试 |
| [cluster/tb/tb_Cluster.sv](RTL/cluster/tb/tb_Cluster.sv) | `cluster_default` | 七种精度、raw 算术与标准时序 |
| 同上 | `sram_rw`、`sram_response`、`sram_*conflict` | SRAM 掩码、同步读响应及读写/计算冲突拒绝 |
| 同上 | `oc_merge`、`act_buffer`、`full_act`、`mixed_context` | OC 合并、ACT 容量、4096bit ACT 及混合 Context |
| 同上 | `input_overlap`、`context_stress`、`os_count_limit` | 接收/发射重叠、复用压力与 OS 边界 |
| 同上 | `requant_integration`、`requant_channel`、`requant_context` | 量化集成、逐通道参数和 Context 映射 |
| 同上 | `requant_buffers`、`requant_a4_address_bypass`、`requant_full_shift` | 固定 Context 槽位、A4 地址旁路、完整 INT10 shift |
| 同上 | `requant_reset`、`requant_boundary`、`requant_empty_batch` | 异步复位、批次边界、空批次到有效批次 |
| 同上 | `gate_equiv_*` | 门控/旁路两套 Cluster 同沿结果与时序比较 |
| 同上 | `requant_negative_*`、`zero_count_*`、`as17_*`、`as64_*`、`context_capacity_*`、`address_capacity_*`、`metadata_capacity_*` | 非法量化配置、零 count 及各类容量越界拒绝 |
| [cluster/tb/tb_ClusterReduceTree.sv](RTL/cluster/tb/tb_ClusterReduceTree.sv) | `reduce_tree` | 208 种归约树、mask 和门控检查 |
| [cluster/tb/tb_ClusterRequant.sv](RTL/cluster/tb/tb_ClusterRequant.sv) | `requant_unit` | Python 整数 golden 与四通道映射 |
| [cluster/tb/tb_Cluster_GEMM_OS1_WS32_W8A16.sv](RTL/cluster/tb/tb_Cluster_GEMM_OS1_WS32_W8A16.sv) | `gemm_os1_ws32_as1_w8a16_{tensor,channel}` | M32 K128 N16，WS32 权重复用 |
| [cluster/tb/tb_Cluster_GEMM_OS2_AS4_W8A16.sv](RTL/cluster/tb/tb_Cluster_GEMM_OS2_AS4_W8A16.sv) | `gemm_os2_ws1_as4_w8a16_{tensor,channel}`、`as_context_*` | M32 K512 N16，跨 Tile 累加、AS4 参数及 5 个负向测试 |
| [cluster/tb/tb_Cluster_GEMM_OS1_WS1_AS8_W8A16.sv](RTL/cluster/tb/tb_Cluster_GEMM_OS1_WS1_AS8_W8A16.sv) | `gemm_os1_ws1_as8_w8a16_{tensor,channel}` | M8 K256 N32，AS8 门控、保持及 Command 切换 |
| [cluster/tb/tb_Cluster_GEMM_W4A16_HighGroup.sv](RTL/cluster/tb/tb_Cluster_GEMM_W4A16_HighGroup.sv) | `gemm_os1_ws8_as1_w4a16_high_group_{tensor,channel}` | W4A16 高归约组及通道映射 |
| [cluster/tb/tb_Cluster_GEMM_W2A8_HighGroup.sv](RTL/cluster/tb/tb_Cluster_GEMM_W2A8_HighGroup.sv) | `gemm_os1_ws8_as1_w2a8_high_group_{tensor,channel}` | W2A8 高归约组及通道映射 |
| [cluster/tb/tb_Cluster_GEMM_W4A16_N6_Tail.sv](RTL/cluster/tb/tb_Cluster_GEMM_W4A16_N6_Tail.sv) | `gemm_os1_ws8_as1_w4a16_n6_tail_{tensor,channel}` | N=6 尾块屏蔽与输出完整性 |
| [cluster/tb/tb_Cluster_GEMM_W4A16_RoundClip.sv](RTL/cluster/tb/tb_Cluster_GEMM_W4A16_RoundClip.sv) | `gemm_os1_ws12_as1_w4a16_round_clip_channel` | 逐通道量化的舍入、正负饱和 |

**PASS 的含义**：正向 GEMM 用例要求 RTL 的 raw / INT8 结果与 Python 按约定整数运算规则生成的 golden 逐元素一致，并通过该用例的时序等检查。这验证的是所测输入下的实现正确性；量化误差是否达标、真实模型的准确率是否保持，需要另行评估。舍入/饱和测试通过也不表示所有矩阵或模型的量化精度达标。

负向用例只有命中预期 Fatal 才算通过，统一以 `make run` 的检查结果为准。完整用例表见 [VCS README](vcs-rtl/README.md)，驱动与 scoreboard 分工见 [TB 指南](docs/Testbench_Guide.md)。

## ICG 门控验证

门控检查覆盖实际时钟的开关、关钟后数据保持，以及门控开启/关闭两套 Cluster 在相同输入下的逐拍等价性。

| CASE（在 vcs-rtl 下执行 make run CASE=名称） | 检查内容 |
|---|---|
| `macro_gate0`、`macro_gate1` | SingleMacro 门控关闭/开启时的算术、时序与保持检查 |
| `reduce_tree` | 208 种归约树、mask 和转发门控检查 |
| `gate_equiv_default` | Cluster 基础计算的门控开关逐拍等价性 |
| `gate_equiv_context_stress`、`gate_equiv_input_overlap` | 多 Context 压力及输入/计算重叠时的等价性 |
| `gate_equiv_requant_buffers`、`gate_equiv_requant_channel` | Context 量化缓存及逐通道量化的等价性 |
| `gate_equiv_requant_reset`、`gate_equiv_requant_boundary` | 复位及批次边界的等价性 |
| `gate_equiv_sram`、`gate_equiv_sram_response` | SRAM 读写、同步读响应的等价性 |
| `requant_full_shift`、`requant_empty_batch` | 完整 INT10 shift 参数及空批次转有效批次的专项检查，启用门控等价对照 |

检查对象包括 Macro 控制/SRAM/ACT 分区时钟、逐 OC 结果时钟、归约转发、tmp/Psum、Context 参数表及 INT8 输出；per-tensor 还检查未使用的 ZP 缓存时钟保持关闭。实现见 [门控检查器](RTL/cluster/tb/include/cluster_gate_checks.svh) 和 [等价检查器](RTL/cluster/tb/include/cluster_gate_equivalence.svh)。

**已有结果与验证范围**：[已保存日志](RTL/cluster/tb/log/cluster_gate_equivalence_validation.log)记录 9 组 Cluster 门控等价检查全部 PASS，共比较 292,941 个周期。这是历史仿真记录，本次文档更新未重跑仿真。PASS 表示所测场景满足 RTL 功能门控及等价检查；当前使用功能 ICG 模型，工艺 ICG 替换后的时序、毛刺及实际功耗需在实现阶段另行验证。

## 详细文档

| 文档 | 需要时查看 |
|---|---|
| [文档索引](docs/README.md) | 全部接口、设计与验证文档 |
| [辅助文件索引](docs/Source_Map.md) | TB include、Python 脚本、共用主体及数据用途 |
| [标准逐拍表](docs/Cluster_Timing_Tables.md) | 原 README 中的 42 组时序表与 26 种 split 编码 |
| [验证清单](docs/Cluster_Verification.md) | 功能覆盖、检查条件及历史验证记录 |

仿真专用函数与综合函数分离：综合函数保留在 rtl/*_func.sv；检查和参考计算函数位于 tb/cluster_check_func.sv（Cluster）与 tb/single_macro_check_func.sv（Macro）。RTL 中对检查函数的 include 均受 `ifndef SYNTHESIS 保护，Macro 还要求 SINGLE_MACRO_ASSERTIONS；定义 SYNTHESIS 后无需读取这些 TB 文件。函数文件均通过模块内 include 使用，不单独编译。
