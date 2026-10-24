# Cluster Testbench

测试顶层、include拆分和观察信号见 [TB指南](../../../docs/Testbench_Guide.md)。所有权重通过常规SRAM口写入并同步读回，再驱动Command/ACT，不通过层次路径注入权重或Psum。

- `tb_Cluster.sv`：raw算术、参数映射、容量、接收/发射重叠及实际门控检查。
- `tb_ClusterReduceTree.sv`：208种树/掩码组合，逐节点/OC检查门控及保持。
- `tb_ClusterRequant.sv`：独立Python整数向量。
- `tb_Cluster_GEMM_OS1_WS32.sv`、`tb_Cluster_GEMM_OS2_AS4.sv`、`tb_Cluster_GEMM_Edges.sv`：11个端到端矩阵case。
- `include/cluster_context_buffer_cases.svh`：AS固定参数槽位、A4地址旁路与参数收集/发射重叠。
- `include/cluster_gate_checks.svh`：Macro计算/存储/Hold、参数组及raw/INT8数据时钟脉冲和保持检查。
- `py/buffer_schedule.py`、`py/generate_readme.py`：调度公式、trace核对及根README的42组逐拍表。

默认Psum及Requant Context深度16、地址表深度16、标签容量64。AS最多16；OS1 WS64可用。Psum使用条件为`cim_os_cnt>1 || (cim_as_cnt>1 && act_bits>4)`。

运行使用 [VCS配置](../../../vcs-rtl/README.md)。所有display及case描述使用英文。
