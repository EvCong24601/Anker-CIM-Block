# Cluster 文档入口

当前版本移除Requant，正式接口为 raw_psum[1023:0] 与 psum_valid[31:0]。以 [原始 Psum 输出契约](Cluster_Raw_Output.md) 和当前 RTL 为准。

当前控制/数据寄存器复位统一为低有效异步 `reset_n`，SRAM wrapper没有复位端口或复位访问保护；上层须在复位期间保持SRAM访问无效，见[SRAM接口说明](Cluster_Weight_SRAM_Interface.md)。旧日志及 history 内归档规格中的原 `reset` 极性不适用于当前接口。

- [当前计算流水总览、51 bit 配置对齐与写入拍点](Cluster_Pipeline.svg) · [PNG](Cluster_Pipeline.png)
- [两拍 Macro 的 ICG 和 W8A8 逐拍示例](Cluster_Pipeline_ICG.svg)
- [raw接口、数值及迁移](Cluster_Raw_Output.md)
- [总体控制切换 README](Cluster_Control_Switching_README.md) · [case 切换与 bubble 详细表](Cluster_Control_Switching_README.md#switch-cases)
- [三通道改版前的资源声明统计](Cluster_DFF_Usage.md)
- [VCS仿真入口](../vcs-rtl/README.md)
- [Macro规格](../RTL/macro/README.md)

当前输入调度、42 组 issue 相对写入表、GEMM、SRAM 和 TB 指南均按两拍 Macro、102 bit 命令、51 bit 逐级配置和 raw 正式输出描述。`buffer_schedule.py`、`audit_latency.py`、单拍 Macro V0.2、Requant 和旧资源统计保留历史标识，不用于当前时序结论。

- [当前三通道实测交接图](Cluster_Issue_Timing.svg) · [输入归属与 ACT 直通](Cluster_Pipeline_A3_A4.svg)
- [当前输入调度](Cluster_Input_Overlap.md) · [42 组写入表](Cluster_Timing_Tables.md)
- [Word 架构与接口规格](CIM_Block_Spec.docx) · [Word 流水与时序说明](CIM_Cluster_逐拍输入时序_v2.8.docx)
- [历史规格归档](history/README.md)
