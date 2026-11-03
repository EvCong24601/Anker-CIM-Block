# Anker CIM Block

当前 Cluster 直接输出 raw_psum[1023:0] 和 psum_valid[31:0]，每个物理 lane 为 signed32。Requant 参数、运算、存储及 INT8 输出已移除。

接口契约、数值布局和迁移说明见 [Cluster 原始 Psum 输出](docs/Cluster_Raw_Output.md)。

## 源码与编译

- RTL/macro/rtl：单 Macro、SRAM、乘法、Slice 融合及门控。
- RTL/cluster/rtl：cluster_top、ClusterReduceTree、共享类型和综合辅助函数。
- RTL/cluster/tb 与 RTL/macro/tb：驱动、独立参考模型、检查函数及场景。
- *_pkg.sv 只保存类型或常量；*_func.sv 在模块内 include，仿真检查函数位于 tb 子目录。
- lib/blackbox 与 lib/cluster_top.lib：当前 raw 输出的接口模型，Liberty 仅用于接口链接。

从 vcs-rtl 运行 make run CASE=cluster_default。GEMM 示例：make run CASE=gemm_os1_ws32_as1_w8a16_raw。make list 列出当前用例。

OS/WS/AS count 各为 9 bit，编码 1～511，Command 共 110 bit。默认 Psum/权重地址深度 16，MAX_CONTEXTS=64；编码范围不等于可用 buffer 容量。

[文档入口](docs/README.md) · [VCS 仿真](vcs-rtl/README.md) · [Macro 规格](RTL/macro/README.md)
