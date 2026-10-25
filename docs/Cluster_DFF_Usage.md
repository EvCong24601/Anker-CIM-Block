# Cluster 主要 DFF 使用统计

统计对象：当前SRAM输出复用与ACT分区门控RTL，基线提交`3be03e0`。默认 `OUTPUT_BUFFER_DEPTH=16`、`REQUANT_CONTEXT_DEPTH=16`、`WGT_RADDR_BUFFER_DEPTH=16`、`MAX_CONTEXTS=64`，8个Macro，`ENABLE_REQUANT=1`、`USE_CLOCK_GATING=1`。

这是按当前RTL时序存储声明展开的位数，由独立TB的`$bits`核对数组及结构体宽度。它不是综合后的DFF单元数或面积：未使用字段、整数高位、常量及重复状态可能被删除、缩位或合并；Psum/参数表也可能映射成其他存储。不能将所有logic、int、longint或乘加中间线网都计成DFF。

## 默认规模

- Cluster顶层：27,974位。
- 8个Macro的逻辑寄存器：4,928位，其中SRAM输出行号/有效位72位。
- 归约树：584位，其中转发数据464位、控制和门控请求120位。
- 上述名义合计：33,486位，不含权重SRAM、SRAM读出保持模型和ICG锁存器。
- SRAM同步读出保持模型另有8,192位；连同它一起按RTL行为模型统计为41,678位。物理SRAM IP若已包含读出保持，不能再次作为外部DFF重复估算。
- ICG模型另有684个低电平锁存位，它们属于latch/ICG，不是DFF。
- 权重阵列为2,097,152bit，即256KiB/Cluster；预期映射SRAM，不计入逻辑DFF。实际是否推导或绑定SRAM须由综合及宏替换确认。

## 寄存器明细

| 存储 | 名义位数 | 展开式 |
|---|---:|---|
| Psum 数据 | 16,384 | `1024*D` |
| tmp 数据 | 1,024 | `1024` |
| Cluster ACT | 4,096 | `4096` |
| Requant Context表和valid | 4,752 | `297*Q` |
| 批次Requant参数 | 298 | `298` |
| 深权重地址表和A4当前地址 | 136 | `8*W+8` |
| Raw数据组合视图 | 0 | `0` |
| 三路径Raw Context指针 | 18 | `3*C` |
| Raw有效位 | 32 | `32` |
| INT8输出和valid | 288 | `288` |
| Packet地址和共享Batch描述符 | 115 | `115` |
| 四级共享流水标签 | 68 | `4*(11+C)` |
| 三路径tmp标签和逐lane valid | 83 | `3*(11+C)+32` |
| 三路径完成状态 | 3 | `3` |
| Buffer门控请求及深度开关 | 560 | `32+33*D` |
| 调度及Hold跟踪 | 113 | `93+C+2*L` |
| SRAM响应编号和valid | 4 | `4` |
| 8 Macro ACT | 4,096 | `4096` |
| 8 Macro SRAM输出行号和有效位 | 72 | `72` |
| 8 Macro结果 | 576 | `576` |
| 8 Macro输入控制 | 120 | `120` |
| 8 Macro输出元数据 | 56 | `56` |
| 8 Macro读valid | 8 | `8` |
| 归约转发寄存器 | 464 | `464` |
| 归约控制和门控请求 | 120 | `120` |

## 数据路径与标签说明

- 32路tmp数据共1,024bit，32路最终INT8数据仅256bit，INT8 valid另32bit；Requant乘法、移位和舍入为组合逻辑，不存在大移位寄存器或内部算术流水。
- Cluster ACT bank为4,096bit；8个Macro还各有512bit输入ACT寄存器，合计另4,096bit。这是两个实际寄存边界，不应只统计其中一份。
- Macro乘积、Slice融合及五级加法树均为组合网络；只统计每OC最终18bit结果。
- `act_complete`为已声明但未被功能读取的1bit状态；共享标签的组合视图不是DFF。因此33,486是声明级名义值，不能称为综合后精确值。
- 排除仅仿真的操作/门控计数器及初始化检查表。top八个操作统计int和Reduce诊断数组的声明规模合计896bit，不属于功能DFF；Macro initialized_ocs属于仿真检查状态。

## 参数影响

令D为OUTPUT_BUFFER_DEPTH、Q为REQUANT_CONTEXT_DEPTH、W为WGT_RADDR_BUFFER_DEPTH、M为MAX_CONTEXTS，C=max(1,ceil(log2(M)))，L=max(1,ceil(log2(M+1)))。相同RTL结构、8 Macro且ENABLE_REQUANT=1时，声明级统计为：

`N_RTL = 11614 + 11*C + 2*L + 1057*D + 297*Q + 8*W`

当D=Q=W且M=64时，深度8/16/32分别为22,590/33,486/55,278bit；三组均经独立TB展开核对。这只是资源规模变化，不表示所有参数组合均满足AS地址/标签/参数容量合同。

运行时AS/WS、A4/A8/A16、OC mask或per-tensor配置影响时钟活动及写使能，不会直接减少已经实例化的寄存器容量。USE_CLOCK_GATING=0仅旁路ICG，数据保持使能仍在；其ICG锁存器不实例化。

## 证据

独立测试台、三组展开日志和逐项表达式保存在本地`cluster_tb_work/local_sim/compact_control_dff_audit_20261025/`。默认详细数据同时见`Cluster_DFF_Usage.csv`。本次未执行实际综合、SRAM宏映射或STA。

Macro ACT输入使用三个独立ICG，按当前W精度分别捕获512/256/128bit，未使用区保持。8 Macro共72个ICG，Cluster顶层588个，Reduce24个，默认总计684个ICG锁存位；通用公式为`172+32*D`。ACT数据DFF数量仍为4096bit，容量不随运行精度变化。

权重不再从SRAM输出复制到held_weight。每Macro仅保留8bit行号和1bitvalid，read_address_in/station_in及独立Hold时钟也不实例化。相对含独立Hold的版本，数据DFF减少8192bit、冗余输入状态减少72bit；SRAM读出保持模型8192bit仍单列，不能与已删除的数据副本混为一谈。

Macro内部held_address/hold_valid当前供协议断言读取；Cluster顶层另有功能性的输出行跟踪来产生station。综合可能删除Macro内部这些仅用于检查的标签副本，声明级统计仍按当前源码列出72bit。

## 共享事务标签与结果存储

批次描述符由整个 Cluster 共享。四级流水仅携带 valid、Slice、Context 和 K Tile；tmp 标签按 2/4/8 Macro 三种归约延迟路径共享，lane 通过批次的归约配置选择路径。默认 Context 宽6bit，每个窄标签17bit；四级流水68bit、三路径 tmp 标签51bit，逐lane tmp valid另32bit。三路径 raw Context 指针共18bit。逐lane兼容视图为组合连线，不复制配置寄存器。

Psum 使用条件为 `cim_os_cnt>1 || cim_as_cnt>1`。OS1/AS2～16（含 A4）按 Context 保存结果；深度16允许AS16，AS17/AS64拒绝。AS的 Tile→Slice→Context 发射顺序以及包内接收/发射重叠保持。A4仅旁路深权重地址表，Requant Context 参数仍须保留至消费。

raw 数据直接选择对应 Context 的 Psum 或单 Context/WS 的 tmp，不另设1024bit raw DFF。raw valid 保持原发布时刻，INT8 输出寄存器及 valid 仍晚1T。无效周期 raw 视图可能变化；正式 INT8 输出在无 valid 时保持。各路径指针和标签按提前门控请求更新。

相对逐lane完整标签和独立raw数据寄存器的结构，名义DFF减少10407bit。Requant Context表仍为4752bit：16×(4×32bit multiplier + 4×10bit shift + 4×32bit ZP + 1bit valid)。它按Context保存量化参数，未包含raw数据；per-tensor会门控未使用scale通道，但不改变实例容量。

## 统一 Buffer 深度

集成使用 `OUTPUT_PSUM_DEPTH`（默认16）统一设置 Psum、权重CIM读地址表及Requant Context参数表深度。兼容参数依赖为 `OUTPUT_BUFFER_DEPTH=OUTPUT_PSUM_DEPTH`，`WGT_RADDR_BUFFER_DEPTH=OUTPUT_BUFFER_DEPTH`，`REQUANT_CONTEXT_DEPTH=OUTPUT_BUFFER_DEPTH`；仅覆盖统一参数即可联动三表。容量负向测试可以显式覆盖兼容参数，显式覆盖会优先于默认联动。MAX_CONTEXTS为独立的调度标签容量，仍须满足其限制。

每个物理输出OC由acc和bit-fusion共用一个组合加法器，全部Context通过Psum索引复用；不同OC之间保持独立，以支持并行输出。Context深度只扩展状态存储，不复制算术单元。

## 完成跟踪和调度状态

每条有效归约路径按Context顺序返回，延迟固定且没有输出反压。三位completion_path_done记录各路径最后一个Context完成；与batch_input_done及组合生成的路径需求共同决定batch关闭。空路径不等待结果，本拍最终结果参与本拍关闭判断。逐Context/lane预留、重复写和提前关闭检查位于TB的cluster_completion_checks.svh，不计入功能DFF。引入乱序返回或输出反压时须重新设计此条件。

packet_cmd是组合视图，复用107bit batch_command，只另存8bit packet_weight_address，共115bit。批次配置变化仍触发协议错误。

phase/external_phase各2bit，context_idx为C bit，command_count/batch_contexts各L bit，tile为8bit。默认六个状态合计32bit，相对六个int32减少160bit；数量64需要7bit，索引0～63需要6bit。phases/contexts为组合解码。

相对共享事务标签后的37838bit版本：完成跟踪减少4093bit，描述符减少99bit，计数器减少160bit，合计4352bit，默认33486bit。shift接口及存储仍为INT10，没有进行shift压缩；完整INT10运算通过组合范围判定支持，不增加寄存器。Psum仍为32个物理lane，本次未实施四通道压缩。
