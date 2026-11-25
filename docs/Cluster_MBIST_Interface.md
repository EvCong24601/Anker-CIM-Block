# Cluster 权重 SRAM 自检接口

MBIST 是 SRAM 的内建自测试。本工程用 3 位编号从 8 个 Macro 中选择一个。**一次启动同时测试该 Macro 的两块 `256×512` SRAM**，每块使用一份原版 v2 `hdsram256w512b_mbist_top`，两块都完成后才发布 Macro 的结果。[SRAM 接线与状态合并](../RTL/macro/rtl/MacroWeightSRAM.sv#L26)

## 顶层端口

方向以 `cluster_top` 为准。[RTL 端口定义](../RTL/cluster/rtl/cluster_top.sv#L57)

| 端口 | 方向 | 位宽 | 含义 |
|---|---|---:|---|
| `mbist_macro_id_i` | 输入 | 3 | 本轮要测的 Macro 编号，范围 0～7 |
| `mbist_test_red_sbk_i` | 输入 | 64 | 该 Macro 的完整修复配置，随启动请求一同提交 |
| `mbist_test_memory_start_i` | 输入 | 1 | Cluster 空闲时拉高一拍，发起一轮自检 |
| `mbist_test_busy_o` | 输出 | 1 | 从接受请求到发布结果一直为 1 |
| `mbist_test_done_o` | 输出 | 1 | 本轮两块 SRAM 已完成，顶层结果已就绪 |
| `mbist_test_memory_valid_o` | 输出 | 1 | 两块 SRAM 在本轮配置下都通过 |
| `mbist_out_of_repair_o` | 输出 | 1 | 任一块 SRAM 在本轮报告超出修复能力 |
| `mbist_test_error_sbk_o` | 输出 | 64 | 本轮 8 个小区的错误报告，每区 8 位 |

## 启动与结果

1. 等 Cluster 的正常计算和 SRAM 访问结束，再提交编号、完整修复配置和一拍 `start`。顶层在上升沿锁存编号与配置，并拉高 `busy`。忙期间发来的启动脉冲会被忽略。
2. 下一拍只有选中的 Macro 更新自己的 64 位 `repair_config`，并产生本地启动脉冲。再下一拍，两块 SRAM 一起启动。每个 Macro 的配置持续用于自检和正常读写，直到复位或该 Macro 接收新的配置。
3. 顶层先等选中 Macro 的底层 `busy`，再等两块 SRAM 都完成，避免把上一轮残留的 `done` 当成本轮结果。在 `done=1`、`busy=0` 时读取报告和状态。结果保留到接受下一轮请求或复位。

[顶层控制](../RTL/cluster/rtl/cluster_top.sv#L176) · [Macro 本地配置与启动](../RTL/macro/rtl/SingleMacro.sv#L60)

## 配置、报告和复测

- 配置和报告采用相同的字节顺序。`[31:0]` 对应低 512 位 SRAM（OC0/1），`[63:32]` 对应高 512 位 SRAM（OC2/3）。每半的字节从低到高依次对应 `sbk0` 到 `sbk3`，每个小区有 128 个普通列。[字节接线](../RTL/macro/rtl/MacroWeightSRAM.sv#L55)
- 每个配置字节的 bit 7 是修复使能，低 7 位是区内列号。报告字节的 bit 7 表示有普通列错误，低 7 位给出一个出错列号。完整错误位图 `test_error_BL` 和备用列读数 `redsbk0OUT` 到 `redsbk3OUT` 留在 wrapper 内部。[v2 修复配置解码](../RTL/macro/rtl/hdsram256w512b_mbist_top.sv#L644)
- 例如首次测 5 号 Macro 可以送全 0 配置。如果返回 `memory_valid=0`、`out_of_repair=0`，报告最低字节为 `8'h8C`，可以把低块 `sbk0` 的配置设成 `8'h8C` 后再测 5 号。每次启动都会覆盖该 Macro 的完整 64 位配置，已启用的其他修复也要一并带上。
- `out_of_repair` 由原版控制器根据本轮错误分布判定，Cluster 汇总两块 SRAM 的结果。配置修复后仍然测错时，由外部结合复测记录决定如何处理。自检会覆盖被测 Macro 的权重，恢复计算前需要重新装载。[v2 结果判定](../RTL/macro/rtl/hdsram256w512b_mbist_top.sv#L421) · [首测、修复复测和切换 Macro 的测试](../RTL/cluster/tb/tb_ClusterMbist.sv#L128)
