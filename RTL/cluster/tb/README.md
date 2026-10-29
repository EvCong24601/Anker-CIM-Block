# Cluster Testbench

测试顶层、include拆分和观察信号见 [TB指南](../../../docs/Testbench_Guide.md)。所有权重通过常规SRAM口写入并同步读回，再驱动Command/ACT，不通过层次路径注入权重或Psum。

- `tb_Cluster.sv`：raw算术、参数映射、容量、接收/发射重叠及实际门控检查。
- `tb_ClusterReduceTree.sv`：208种树/掩码组合，逐节点/OC检查门控及保持。
- `tb_ClusterRequant.sv`：独立Python整数向量。
- `tb_Cluster_GEMM_OS1_WS32_W8A16.sv`、`tb_Cluster_GEMM_OS2_AS4_W8A16.sv`、`tb_Cluster_GEMM_OS1_WS1_AS8_W8A16.sv`及四个按精度和场景命名的 `tb_Cluster_GEMM_W*.sv`：13个端到端矩阵case。`ClusterGemmScenario.sv`、`ClusterGemmOs1Ws32.sv`、`ClusterGemmOs2As4.sv`共用驱动和检查逻辑。
- `include/cluster_context_buffer_cases.svh`：AS固定参数槽位、A4地址旁路与参数收集/发射重叠。
- `include/cluster_gate_checks.svh`：Macro控制/存储/ACT分区、参数组及共享路径标签及INT8数据时钟脉冲和保持检查。
- `py/buffer_schedule.py`、`py/generate_readme.py`：调度公式、trace核对及根README的42组逐拍表。

默认Psum及Requant Context深度16、地址表深度16、标签容量64。AS最多16；OS1 WS64可用。Psum使用条件为`cim_os_cnt>1 || cim_as_cnt>1`。

运行使用 [VCS配置](../../../vcs-rtl/README.md)。所有display及case描述使用英文。

## 统一 Buffer 深度

集成使用 `OUTPUT_PSUM_DEPTH`（默认16）统一设置 Psum、权重CIM读地址表及Requant Context参数表深度。兼容参数依赖为 `OUTPUT_BUFFER_DEPTH=OUTPUT_PSUM_DEPTH`，`WGT_RADDR_BUFFER_DEPTH=OUTPUT_BUFFER_DEPTH`，`REQUANT_CONTEXT_DEPTH=OUTPUT_BUFFER_DEPTH`；仅覆盖统一参数即可联动三表。容量负向测试可以显式覆盖兼容参数，显式覆盖会优先于默认联动。MAX_CONTEXTS为独立的调度标签容量，仍须满足其限制。

每个物理输出OC只有一套acc与一套bit-fusion组合算术，全部Context通过Psum索引复用；不同OC之间保持独立，以支持并行输出。Context深度只扩展状态存储，不复制算术单元。

`include/cluster_completion_checks.svh`独立检查逐Context/lane的预留、唯一发布和完整批次结束；检查表属于TB，不进入RTL。

## Per-tensor ZP修正

per-tensor DUT输出为不加ZP、已饱和的INT8；TB使用`requant_tb_helpers.svh`按逻辑channel加signed INT32 ZP并再次饱和。先检查`cim_golden.hex`，再检查修正后的`quant_golden.hex`；输出周期及保持仍直接检查DUT。必须重新生成数据，原算法参考另存`original_quant_reference.hex`。per-channel直接比较原DUT量化输出，不做TB二次修正。
