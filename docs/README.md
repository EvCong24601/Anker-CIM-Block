# Cluster 文档索引

接口以 `RTL/cluster/rtl/cluster_top.sv` 为准：输入Command、ACT和常规SRAM读写；最终结果为Requant数据及valid。raw Psum只在TB中观察。

- [输入时序、调度与容量](Cluster_Input_Overlap.md)：同包接收/发射重叠、WS/AS顺序、OS1 bit fusion、地址表与Psum容量、逐拍公式。
- [SRAM接口](Cluster_Weight_SRAM_Interface.md)：Macro/行寻址、32 B写mask、读写时序、互斥、Hold及访问检查。
- [Requant](Cluster_Requant.md)：四通道参数映射、per-tensor/per-channel scale、合并zp、AS独立scale/zp参数表、INT8输出寄存及1T valid、Psum中间截断与溢出处理TBD。
- [GEMM用例](Cluster_GEMM.md)：全部13个正向、5个AS参数负向case，矩阵、权重布局、时序、参数、golden和TB分工；AS8覆盖buffer门控及Command切换。
- [Testbench指南](Testbench_Guide.md)：源码结构、内部观察信号、golden/scoreboard、采样和日志职责。

运行配置统一见 [VCS说明](../vcs-rtl/README.md)。Word文件为独立规格文件；端口连接和仿真入口按当前RTL及上述Markdown使用。

- [验证清单](Cluster_Verification.md)：调度、容量、Context参数、OC门控、整Cluster逐拍对照及同步SRAM证据。
- [十轮检查与问题记录](Cluster_Bug_Review.md)：完整 INT10、空批次门控、Psum 溢出与未知控制检查的复现及验证范围。

- [Macro ACT分区门控](Cluster_ACT_Gating.md)：W2/W4/W8的512/256/128bit捕获、输入精度切换与门控验证。

Per-tensor当前采用CIM先饱和到INT8、TB按channel加ZP后再次饱和的边界；per-channel保留CIM内加ZP。公式、兼容字段和golden分工见[Requant](Cluster_Requant.md)。

- [源码辅助文件索引](Source_Map.md)：TB include、Python、数据与记录的用途。
- [标准逐拍表](Cluster_Timing_Tables.md)：42组raw时序表及26种split编码，由generate_readme.py生成。

当前Command接口：OS/WS/AS count各9bit，范围1～511，compute descriptor共110bit。编码范围与缓冲容量限制分别见输入时序说明；两份Word规格已同步更新。SRAM行地址仍为8bit。
