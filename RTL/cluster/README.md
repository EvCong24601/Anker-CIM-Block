# Cluster 功能实现

cluster_top 的正式输出为 raw_psum[1023:0] 和 psum_valid[31:0]。每个 lane 为 signed32，valid 按物理 lane 对应，无输出反压；无效周期数据不保证保持。没有 Requant 或额外 INT8 输出拍。

详细接口见 [原始 Psum 输出契约](../../docs/Cluster_Raw_Output.md)。

复位接口为低有效异步 `reset_n`，仅连接有复位状态的子模块，不参与请求、ready 或时钟使能的组合译码。Command握手仅在 `reset_n=1` 时有效；复位期间输出有效位为0。SRAM wrapper无复位端口或访问保护，上层须将 `sram_cs_en` 置0以保持SRAM内容。

rtl/ 包含 cluster_top.sv、ClusterReduceTree.sv、cluster_pkg.sv 和 cluster_func.sv。tb/ 包含仿真检查函数及 TB；cluster_pkg 只包含类型，Cluster 函数通过模块内 include 使用。

从本目录使用 rtl/filelist.f；从 tb/ 使用 filelist.f；从仓库 vcs-rtl/ 使用 verilog_file_*.f。所有 include 搜索路径已在对应清单中配置。SYNTHESIS 定义排除 RTL 中的仿真协议检查。

OS/WS/AS count 各9bit、范围1～511，Command 共102bit，最低位为 cim_signed_en。DW 按 K=256，W2/W4/W8 分别使用2/4/8个完整ACT槽和Macro，由OC、split、enable mask控制。每个任务握手一次 cmd，weight 和 ACT 各自按序传输。两路的首个操作数可在 cmd 握手沿接收。默认OUTPUT_PSUM_DEPTH=16统一设置Psum及权重地址深度；MAX_CONTEXTS默认64。WS/AS不能同时大于1，容量限制继续有效。

下游使用随事务传递的51bit pipeline_cfg_t，各级独立控制归约、ICG、累加和输出。单宽度任务按实际路径类别（Reduce-1/2、Reduce-4、Reduce-8）、A位宽和累加模式判断跨split交接；原有同split的mask兼容保留。检查覆盖所有实际在途事务及待写回Psum，空任务不能掩盖旧类别。enable/OC、兼容计数、ACT slot、符号和同A精度的W变化仍可重叠在途结果。
