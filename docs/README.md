# Cluster 文档索引

接口以 `RTL/cluster/rtl/cluster_top.sv` 为准：输入Command、ACT和常规SRAM读写；最终结果为Requant数据及valid。raw Psum只在TB中观察。

- [输入时序、调度与容量](Cluster_Input_Overlap.md)：同包接收/发射重叠、WS/AS顺序、OS1 bit fusion、地址表与Psum容量、逐拍公式。
- [SRAM接口](Cluster_Weight_SRAM_Interface.md)：Macro/行寻址、32 B写mask、读写时序、互斥、Hold及访问检查。
- [Requant](Cluster_Requant.md)：四通道参数映射、per-tensor/per-channel scale、合并zp、AS参数表、INT8输出寄存及1T valid。
- [GEMM用例](Cluster_GEMM.md)：全部11个正向、3个负向case，矩阵、权重布局、时序、参数、golden和TB分工。
- [Testbench指南](Testbench_Guide.md)：源码结构、内部观察信号、golden/scoreboard、采样和日志职责。

运行配置统一见 [VCS说明](../vcs-rtl/README.md)。Word文件为独立规格文件；端口连接和仿真入口按当前RTL及上述Markdown使用。
