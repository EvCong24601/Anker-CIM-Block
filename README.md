# Anker CIM Block

当前 Cluster 直接输出 raw_psum[1023:0] 和 psum_valid[31:0]，每个物理 lane 为 signed32。Requant 参数、运算、存储及 INT8 输出已移除。

Cluster/Macro/ReduceTree 统一使用低有效异步复位 reset_n（原 reset 端口已更名）。复位不参与端口使能的组合译码；SRAM wrapper不含复位端口，上层须在复位期间保持SRAM访问无效，存储内容保留。

接口契约、数值布局和迁移说明见 [Cluster 原始 Psum 输出](docs/Cluster_Raw_Output.md)。

## 源码与编译

- RTL/macro/rtl：单 Macro、SRAM、乘法、Slice 融合及门控。
- RTL/cluster/rtl：cluster_top、ClusterReduceTree、共享类型和综合辅助函数。
- RTL/cluster/tb 与 RTL/macro/tb：驱动、独立参考模型、检查函数及场景。
- Cluster 的 *_pkg.sv 保存类型，*_func.sv 在模块内 include。Macro 的 single_macro_pkg.sv 沿用上游常量及函数，详见 [Macro 集成说明](RTL/macro/README.md)。
- lib/blackbox 与 lib/cluster_top.lib：当前 raw 输出的接口模型，Liberty 仅用于接口链接。

从 vcs-rtl 运行 make run CASE=cluster_default。GEMM 示例：make run CASE=gemm_os1_ws32_as1_w8a16_raw。make list 列出当前用例。

Command 为 103 bit，最低位 `cim_dw_compact` 选择紧凑深度卷积 ACT 排布，每个任务握手一次。首个 8 bit 权重行地址和首个 1024 bit ACT plane 均可在该沿或之后独立握手。OS/WS/AS count 各为 9 bit，编码 1～511。默认 Psum/权重地址深度为 16，MAX_CONTEXTS=64。

[文档入口](docs/README.md) · [VCS 仿真](vcs-rtl/README.md) · [Macro 规格](RTL/macro/README.md)
