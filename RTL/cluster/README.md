# Cluster 功能代码与验证目录

Cluster 目录只分为 rtl/ 与 tb/ 两个职责：功能实现放 rtl/，验证源码、脚本和记录放 tb/。

```text
RTL/cluster/
  rtl/
    cluster_pkg.sv          共享命令类型、精度和归约辅助函数
    ClusterRequant.sv       四通道组合Requant，scale可共享或逐OC
    ClusterReduceTree.sv    归约树、有效位与转发门控逻辑
    cluster_top.sv          功能参考顶层，八个Macro归约与最终Requant输出
    filelist.f             仅功能源码及 Macro 依赖，不包含 TB
  tb/
    tb_Cluster.sv          Cluster 仿真顶层
    tb_ClusterReduceTree.sv 归约树单元测试
    tb_ClusterRequant.sv    无时钟Requant算术单元测试
    tb_Cluster_GEMM_OS1_WS32_W8A16.sv      单Cluster四批N4的W8A16 M32/K128/N16矩阵验证
    tb_Cluster_GEMM_OS2_AS4_W8A16.sv 单Cluster八Macro归约的M32/K512/N16验证
    latency_audit.sv       仿真时延观察器
    include/              驱动、参考模型、检查器、case 与 suite
    py/                   回归入口、数据生成与时延核对
    data/                 已记录的 CSV
    log/                  已记录的验证日志
    filelist.f            仿真源码清单，包含 ../rtl 中的功能实现
    README.md             测试说明
```

rtl/ 中的 cluster_top 仍是当前功能参考实现，目录名称不代表已经完成生产综合或 STA。tb_*.sv、latency_audit.sv 和 include 中的测试逻辑均不属于功能模块。

当前支持同一包内 ACT/AS 地址接收与内部发射重叠，发射只等待当前 Plane 和 Context 地址就绪。调度规则、无空拍公式与 168 例专项说明见 [Cluster 输入重叠说明](../../docs/Cluster_Input_Overlap.md)。

Requant配置为297bit：conv_mode（1=weight per-channel，0=weight per-tensor）、4×INT32 multiplier、4×INT10 shift、4×INT32 zp；compute descriptor 为107 bit。scale和合并后的zp均按OC0～3固定对应oc_mask，所有启用Requant的计算仅允许一组、最多4OC。per-channel AS4保存512bit zp和672bit scale，每拍选4项。per-tensor每Context仅加载第0组scale、不加载ZP，CIM先输出饱和INT8，TB按channel加ZP再饱和。删除requant_mode后配置结构由298bit缩为297bit，输出端口位宽不变。原始多组归约仅在ENABLE_REQUANT=0的raw-only验证中运行。详见 [Requant说明](../../docs/Cluster_Requant.md)、[GEMM用例](../../docs/Cluster_GEMM.md)。

## 编译路径

- 从 RTL/cluster/ 使用 rtl/filelist.f，读取功能源码和 Macro 依赖。
- 从 RTL/cluster/tb/ 使用 filelist.f，+incdir+. 搜索 include/ 中的测试片段；功能文件由 ../rtl/ 引入。
- 从仓库 vcs-rtl/ 运行 make com / make sim；verilog_file_pl.f 指向 ../RTL/cluster/rtl/ 与 ../RTL/cluster/tb/。
- Python 入口位于 tb/py/，同时定位功能 rtl 和验证 tb，并将源码与 include 复制到仓库外的仿真副本。

共享 package 必须在引用它的模块之前编译，.svh 只通过 include 读取。详细验证说明见 [TB README](tb/README.md)；测试职责和修改位置见 [Testbench 阅读指南](../../docs/Testbench_Guide.md)。

GEMM 的配置、检查目标和运行入口见 [GEMM 用例总览](../../docs/Cluster_GEMM.md)。

## 顶层结果端口

`cluster_top` 对外提供 `requant_data_o[255:0]` 和 `requant_valid_o[31:0]`。内部raw形成后的下一沿锁存INT8，valid晚1T；lane按归约组位置映射，每拍最多4个有效，没有输出ready。

`psum_data_o/out_valid_o`在RTL端口表中仅为注释，注明TB用途。TB通过内部raw_data/raw_valid建立观察别名；正式集成只连接最终Requant结果。所有权重写入和读回使用常规cim_*端口。

Per-tensor整个zero-point buffer关钟：AS Context ZP使用`deep_zp_clock`（复用现有`channel_scale_clock`门控域），批次ZP使用`batch_zp_clock`（复用`batch_channel_clock`）。mode=0两者均无时钟脉冲；共享第0项scale仍使用自己的时钟，不受影响。mode=1维持原ZP加载、保持和算术结果；异步复位仍有效。不新增ICG或修改配置容量。TB检查实际ZP时钟电平及存储保持，门控/旁路镜像继续逐拍对照。
