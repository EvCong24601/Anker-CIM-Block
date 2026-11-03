# Cluster 功能实现

cluster_top 的正式输出为 raw_psum[1023:0] 和 psum_valid[31:0]。每个 lane 为 signed32，valid 按物理 lane 对应，无输出反压；无效周期数据不保证保持。没有 Requant 或额外 INT8 输出拍。

详细接口见 [原始 Psum 输出契约](../../docs/Cluster_Raw_Output.md)。

rtl/ 包含 cluster_top.sv、ClusterReduceTree.sv、cluster_pkg.sv 和 cluster_func.sv。tb/ 包含仿真检查函数及 TB；package 只包含类型，函数通过模块内 include 使用。

从本目录使用 rtl/filelist.f；从 tb/ 使用 filelist.f；从仓库 vcs-rtl/ 使用 verilog_file_*.f。所有 include 搜索路径已在对应清单中配置。SYNTHESIS 定义排除 RTL 中的仿真协议检查。

OS/WS/AS count 各9bit、范围1～511，Command共110bit。默认OUTPUT_PSUM_DEPTH=16统一设置Psum及权重地址深度；MAX_CONTEXTS默认64。WS/AS不能同时大于1，容量限制继续有效。
