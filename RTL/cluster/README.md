# Cluster 功能代码与验证目录

Cluster 目录只分为 rtl/ 与 tb/ 两个职责：功能实现放 rtl/，验证源码、脚本和记录放 tb/。

```text
RTL/cluster/
  rtl/
    cluster_pkg.sv          共享命令类型、精度和归约辅助函数
    ClusterRequant.sv       per-tensor组合乘法、缩放、舍入与INT8裁剪
    ClusterReduceTree.sv    归约树、有效位与转发门控逻辑
    cluster_dut_adapter.sv  Cluster 功能参考实现，连接八个 SingleMacro
    filelist.f             仅功能源码及 Macro 依赖，不包含 TB
  tb/
    tb_Cluster.sv          Cluster 仿真顶层
    tb_ClusterReduceTree.sv 归约树单元测试
    tb_ClusterRequant.sv    无时钟Requant算术单元测试
    tb_Cluster_GEMM_OS1_WS32.sv      单Cluster两批N8的W8A16 M32/K128/N16矩阵验证
    tb_Cluster_GEMM_OS2_AS4.sv 单Cluster八Macro归约的M32/K512/N16验证
    latency_audit.sv       仿真时延观察器
    include/              驱动、参考模型、检查器、case 与 suite
    py/                   回归入口、数据生成与时延核对
    data/                 已记录的 CSV
    log/                  已记录的验证日志
    filelist.f            仿真源码清单，包含 ../rtl 中的功能实现
    README.md             测试说明
```

rtl/ 中的 cluster_dut_adapter 仍是当前功能参考实现，目录名称不代表已经完成生产综合或 STA。tb_*.sv、latency_audit.sv 和 include 中的测试逻辑均不属于功能模块。

当前支持同一包内 ACT/AS 地址接收与内部发射重叠，发射只等待当前 Plane 和 Context 地址就绪。调度规则、无空拍公式与 168 例专项说明见 [Cluster 输入重叠说明](../../docs/Cluster_Input_Overlap.md)。

Requant配置为1067bit，不改变107-bit计算descriptor。raw直接进入组合Requant，INT8及valid晚1T。per-tensor共用multiplier/shift，逐weight channel INT32 zp已由参数生成端合入输入补偿。AS4的4组×4项zp表共512bit，每拍选4项。详见 [Requant说明](../../docs/Cluster_Requant.md)、[WS32 GEMM](../../docs/Cluster_GEMM_WS32.md) 和 [OS2 AS4 GEMM](../../docs/Cluster_GEMM_OS2_AS4.md)。

## 编译路径

- 从 RTL/cluster/ 使用 rtl/filelist.f，读取功能源码和 Macro 依赖。
- 从 RTL/cluster/tb/ 使用 filelist.f，+incdir+. 搜索 include/ 中的测试片段；功能文件由 ../rtl/ 引入。
- 从仓库 vcs-rtl/ 运行 make com / make sim；verilog_file_pl.f 指向 ../RTL/cluster/rtl/ 与 ../RTL/cluster/tb/。
- Python 入口位于 tb/py/，同时定位功能 rtl 和验证 tb，并将源码与 include 复制到仓库外的仿真副本。

共享 package 必须在引用它的模块之前编译，.svh 只通过 include 读取。详细验证说明见 [TB README](tb/README.md)；测试职责和修改位置见 [Testbench 阅读指南](../../docs/Testbench_Guide.md)。
