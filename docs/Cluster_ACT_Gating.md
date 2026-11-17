# Macro ACT 按精度分区门控

SingleMacro保留512bit activation_in输入寄存边界，将其分成低128bit、中间128bit和高256bit三个独立时钟域。512 bit 数据容量不变；当前为输入 n、CSA n+1、CPA 结果 n+2 的两拍计算流水，II=1。Command 为 102 bit，不含独立 DW 模式位。

## 位映射与请求

每次发射处理一个4bit ACT Slice，位数由权重精度决定：W2对应128个K元素、512bit；W4对应64个K元素、256bit；W8对应32个K元素、128bit。A4/A8/A16决定Slice数量，不改变单次请求的分区规则。

- activation_in[127:0]：所有有效W2/W4/W8请求捕获。
- activation_in[255:128]：仅有效W2/W4请求捕获。
- activation_in[511:256]：仅有效W2请求捕获。

功能请求译码为 `issue = cim_ren && (|cim_oc_mask)`，不包含复位条件；仅在 `reset_n=1` 时接受事务。空闲或零OC mask时全部ACT区停止时钟并保持旧值；常规SRAM访问不触发ACT捕获。`reset_n=0` 时三个ACT数据区异步清零，输入请求可能仍使ICG开钟，但不会捕获数据。控制、SRAM及逐OC结果使用独立时钟域；权重由SRAM输出保持，行标签随访问域更新。

## 时序与精度切换

ICG请求由当前cim_precision解码，不使用上一笔请求的weight_mode_in。Cluster输入来自已寄存的packet与调度状态；ICG在输入采样沿之前的低电平窗口锁存请求。独立Macro实例仍按输入接口建立/保持要求提前驱动请求，不增加预接收周期。

在接受沿Cn，当前W模式所需全部ACT区与控制同沿捕获。Cn 到 Cn+1 计算并寄存 CSA 中间结果，Cn+1 到 Cn+2 由 CPA 加入符号修正，Cn+2 寄存 Macro 结果；各沿均可接受后续请求。W8切回W2时三段在Cn共同更新，不能等旧weight_mode_in变成W2后才开启高位时钟。

关闭区在非复位期间保持旧内容，乘法路径仅访问当前模式所需范围。三个数据区均使用低有效异步复位 `reset_n`；USE_CLOCK_GATING=0时旁路ICG，但各区仍按同一捕获条件写入，保证与门控配置逐拍一致。

## 资源与功耗范围

每 Macro 的 ACT bank 使用三个 ICG，8 Macro 合计24个；activation_in 共512×8=4096 bit。另有每 OC 的 CSA 与结果 ICG、Macro 主控制和 SRAM 访问 ICG。当前默认门数见[流水与 ICG 图](Cluster_Pipeline_ICG.svg)，不沿用旧版整个 Cluster 的 DFF 总数。

相对每次有效请求都打开512bit ACT时钟，W4仅打开256bit、W8仅打开128bit。这是ACT寄存器时钟负载的变化，不能直接等同于整个Macro的功耗降低比例。ICG自身面积、时钟树、乘加及SRAM保持输出活动需由综合及功耗工具评估。

## 验证

Macro 和 Cluster 检查器在接受沿核对三个实际 ACT 时钟、捕获数据、关闭区保持及异步清零；整 Cluster 门控开关对照比较8 Macro完整 activation_in。当前回归覆盖七精度、INT/UINT、OS/WS/AS、输入重叠、容量拒绝及 SRAM，结果按 raw signed32 比较。K256 专项还核对每笔完整 Macro 输入和真实 bank 时钟。当前验证记录见[验证口径](Cluster_Verification.md)。

主要实现：RTL/macro/rtl/SingleMacro.sv；Macro检查及场景在macro_scoreboard.svh与macro_regression.svh；Cluster检查在cluster_gate_checks.svh与cluster_gate_equivalence.svh。

K256 的 W2/W4/W8 分别使用 2/4/8 个完整 ACT slot；Macro 仍按 W 精度捕获 512/256/128 bit，不存在“DW 仅开低 bank”的特殊规则。
