# Cluster 文档入口

当前版本移除Requant，正式接口为 raw_psum[1023:0] 与 psum_valid[31:0]。以 [原始 Psum 输出契约](Cluster_Raw_Output.md) 和当前 RTL 为准。

当前控制/数据寄存器复位统一为低有效异步 `reset_n`，SRAM wrapper没有复位端口或复位访问保护；上层须在复位期间保持SRAM访问无效，见[SRAM接口说明](Cluster_Weight_SRAM_Interface.md)。Word规格、旧日志及本地备份中的原 `reset` 极性不适用于当前接口。

- [当前两拍 Macro 流水、ICG 和 W8A8 逐拍示例](Cluster_Pipeline_ICG.svg)
- [raw接口、数值及迁移](Cluster_Raw_Output.md)
- [总体控制切换 README](Cluster_Control_Switching_README.md) · [case 切换与 bubble 详细表](Cluster_Control_Switching_README.md#switch-cases)
- [三通道改版前的资源声明统计](Cluster_DFF_Usage.md)
- [VCS仿真入口](../vcs-rtl/README.md)
- [Macro规格](../RTL/macro/README.md)

历史输入重叠说明、时序表及配套 buffer_schedule.py、generate_readme.py 和 audit_latency.py 使用旧版 Command 与首个 ACT 同沿的调度。当前接口按三通道握手运行，使用 channels 用例生成和校验逐拍记录。其余旧设计说明、Word规格和既有日志还可能包含历史 Requant 接口。
