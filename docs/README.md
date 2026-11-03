# Cluster 文档入口

当前版本移除Requant，正式接口为 raw_psum[1023:0] 与 psum_valid[31:0]。以 [原始 Psum 输出契约](Cluster_Raw_Output.md) 和当前 RTL 为准。

- [raw接口、数值及迁移](Cluster_Raw_Output.md)
- [当前资源声明统计](Cluster_DFF_Usage.md)
- [VCS仿真入口](../vcs-rtl/README.md)
- [Macro规格](../RTL/macro/README.md)

其余设计说明、Word规格和既有数据/日志保留此前含Requant版本的历史信息，尤其 requant_cfg_i、INT8 输出及其额外1T、scale/ZP容量和量化专用用例均已失效，不能用于连接当前Cluster。原始归约及调度细节中未涉及Requant的部分可作背景参考。
