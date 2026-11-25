# Cluster 权重 SRAM 自检接口

MBIST 是 SRAM 的内建自测试。本工程用 3 位编号从 8 个 Macro 中选择一个。**一次启动同时测试该 Macro 的两块 `256×512` SRAM**，每块使用一份原版 v2 `hdsram256w512b_mbist_top`，两块都完成后才发布 Macro 的结果。[SRAM 接线与状态合并](../RTL/macro/rtl/MacroWeightSRAM.sv#L26)

## 顶层端口

方向以 `cluster_top` 为准。[RTL 端口定义](../RTL/cluster/rtl/cluster_top.sv#L57)

旧的单比特 `mbist_repair_done_i` 暂时停用，由 8 位状态取代。

| 端口 | 方向 | 位宽 | 含义 |
|---|---|---:|---|
| `mbist_macro_id_i` | 输入 | 3 | 本轮要测的 Macro 编号，范围 0～7 |
| `mbist_test_red_sbk_i` | 输入 | 64 | 写入当前 `mbist_macro_id_i` 选中 Macro 的完整修复配置 |
| `mbist_repair_we_i` | 输入 | 1 | Cluster 共用写使能；`we=1` 的时钟上升沿只写选中 Macro 的 64 位修复寄存器，`we=0` 时全部保持 |
| `mbist_test_memory_start_i` | 输入 | 1 | Cluster 空闲时拉高一拍，发起一轮自检 |
| `mbist_repair_done_o` | 输出 | 8 | 每位对应一个 Macro；修复写入边沿 N 后在 N+3 置位，下一次写同一 Macro 时清零，`rstn_config` 清零全部位 |
| `rstn_config` | 输入 | 1 | 低有效异步复位，清零每个 Macro 的 64 位修复寄存器及 8 位完成状态；独立于 MBIST 控制复位 `reset_n` |
| `mbist_test_busy_o` | 输出 | 1 | 从接受请求到发布结果一直为 1 |
| `mbist_test_done_o` | 输出 | 1 | 本轮两块 SRAM 已完成，顶层结果已就绪 |
| `mbist_test_memory_valid_o` | 输出 | 1 | 两块 SRAM 在本轮配置下都通过 |
| `mbist_out_of_repair_o` | 输出 | 1 | 任一块 SRAM 在本轮报告超出修复能力 |
| `mbist_test_error_sbk_o` | 输出 | 64 | 本轮 8 个小区的错误报告，每区 8 位 |

## 启动与结果

1. 给出 Macro 编号和完整修复配置，并将 Cluster 共用的 `mbist_repair_we_i` 拉高一拍。选中的 Macro 在上升沿把 64 位输入采样到自己的 `repair_config`；Cluster 顶层没有第二份 64 位修复码寄存器。`we=0` 时八个 Macro 均保持。
2. 修复码在该上升沿写入选中 Macro 的本地寄存器，同时清零 `mbist_repair_done_o[macro_id]`。写入边沿记为 N，N+3 的上升沿后该位变为 1 并保持；写其他 Macro 不影响此位。连续写同一个 Macro 时，以最后一次写入为准。这个标志是 Cluster 计数的协议状态，底层 SRAM wrapper 没有独立的 repair 完成端口。
3. 等 Cluster 的正常计算和 SRAM 访问结束，将 `start` 拉高一拍。顶层在上升沿采样启动请求和 Macro 编号；后续只向该 Macro 发本地启动脉冲，两块 SRAM 一起启动。`start` 不写修复寄存器，忙期间发来的启动脉冲会被忽略。
4. 顶层先等选中 Macro 的底层 `busy`，再等两块 SRAM 都完成，避免把上一轮残留的 `done` 当成本轮结果。在 `done=1`、`busy=0` 时读取报告和状态。结果保留到接受下一轮请求或 `reset_n` 复位；每个 Macro 的修复配置由独立的 `rstn_config` 清零。

[顶层控制](../RTL/cluster/rtl/cluster_top.sv#L176) · [Macro 本地配置与启动](../RTL/macro/rtl/SingleMacro.sv#L60)

## 配置、报告和复测

- 配置和报告采用相同的字节顺序。`[31:0]` 对应低 512 位 SRAM（OC0/1），`[63:32]` 对应高 512 位 SRAM（OC2/3）。每半的字节从低到高依次对应 `sbk0` 到 `sbk3`，每个小区有 128 个普通列。[字节接线](../RTL/macro/rtl/MacroWeightSRAM.sv#L55)
- 每个配置字节的 bit 7 是修复使能，低 7 位是区内列号。报告字节的 bit 7 表示有普通列错误，低 7 位给出一个出错列号。完整错误位图 `test_error_BL` 和备用列读数 `redsbk0OUT` 到 `redsbk3OUT` 留在 wrapper 内部。[v2 修复配置解码](../RTL/macro/rtl/hdsram256w512b_mbist_top.sv#L644)
- 例如首次测 5 号 Macro 可以保持全 0 配置。如果返回 `memory_valid=0`、`out_of_repair=0`，报告最低字节为 `8'h8C`，可以在 `start=0` 时把低块 `sbk0` 的配置设成 `8'h8C`，脉冲写使能后复测。每次 `we=1` 都整组覆盖选中 Macro 的 64 位配置，已启用的其他修复也要一并带上。
- `out_of_repair` 由原版控制器根据本轮错误分布判定，Cluster 汇总两块 SRAM 的结果。配置修复后仍然测错时，由外部结合复测记录决定如何处理。自检会覆盖被测 Macro 的权重，恢复计算前需要重新装载。[v2 结果判定](../RTL/macro/rtl/hdsram256w512b_mbist_top.sv#L421) · [首测、修复复测和切换 Macro 的测试](../RTL/cluster/tb/tb_ClusterMbist.sv#L128)
