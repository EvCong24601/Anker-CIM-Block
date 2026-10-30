# Cluster 验证清单

本清单对应当前RTL、TB及VCS用例目录。检查功能结果、周期和实际门控行为；物理SRAM IP、综合后门控结构及STA由集成流程验证。

## 调度与容量

- [x] 七种精度、UINT/INT、OS1/2、Single/WS/AS、有无命令空拍：`cluster_default`、`input_overlap`、`requant_channel`。检查输入寄存后一拍发射、Slice/Context/Tile顺序及输出周期。
- [x] AS16正向：`context_stress`、`requant_buffers`，覆盖OS1/2。OS1 WS64及OS2 WS8/AS8分别检查，Context之间不串数据。
- [x] AS17、AS64拒绝：七精度×两种符号×OS1/2，必须命中`CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。地址、标签、参数深度不足分别匹配对应诊断。

所有AS采用Tile→Slice→Context，默认最多16个Context。Psum使用条件为`cim_os_cnt>1 || cim_as_cnt>1`，每OC最多一个Context项在同一沿写入，高地址项整批关钟。

## Context量化参数与OC映射

- [x] `requant_context`：OS1/2、两种scale模式；不同Context的multiplier、shift、ZP均不同，32个INT8值与独立整数预期比对。
- [x] `requant_buffers`：七精度、AS8/AS16、OS1/2，两种scale模式，77个case及2912个raw、2912个INT8比对。Context shift按编号变化，首Tile加载、后续Tile校验、最终结果按Context取参数。
- [x] `requant_channel`与GEMM：16种OC mask、七种对齐组、高位置物理lane、N尾部；参数c固定对应OC c。
- [x] Per-tensor在OC0被屏蔽时仍取当前Context的第0项scale；未使用的三组scale/shift寄存器保持。per-tensor不加载/消费ZP，TB修正；per-channel四项ZP仍按本地OC索引。

## A4地址旁路与接收发射重叠

- [x] `requant_a4_address_bypass`：`WGT_RADDR_BUFFER_DEPTH=1`，22个A4 case，832个raw及832个INT8比对；权重深表时钟关闭，Requant固定Context表正常保留参数。
- [x] `input_overlap`：168个case，检查ACT尾部采样/地址接收与已有输入发射重叠，当前地址未到达时暂停并正确恢复。
- [x] `requant_buffers`：每个case必须在Context命令尚未收齐时已经发射，否则报告`AS waited for all Context parameters before issuing`。

## 门控与逐拍一致性

- [x] 子节点消费需求：`reduce_tree`用独立祖先路径模型核对两层转发门控；整Cluster检查Macro结果需求在输入沿寄存、被屏蔽子节点的实际时钟和输出保持，以及两侧关钟时父节点加法器输入/和保持。独立终点继续与数值golden及原时序比对。两层分别覆盖39次pair、5次四Macro本地有效而祖先屏蔽的转发关钟；额外42651周期检查计算数据路径使能从前一沿建立后保持到捕获沿。
- [x] 实际脉冲及保持：Macro控制与SRAM访问域、Macro逐OC结果、归约树逐节点/OC、tmp/Psum、raw/INT8逐lane、Context参数组均由检查器验证。
- [x] `gate_equiv_default`：同输入的门控实例与全ICG旁路实例逐拍比较，覆盖raw归约布局、七精度、WS/AS和Tile累加。
- [x] `gate_equiv_requant_buffers`、`gate_equiv_requant_channel`：不同Context参数、量化映射及masked OC保持值逐拍一致。
- [x] `gate_equiv_context_stress`、`gate_equiv_input_overlap`：大Context、接收/发射重叠和命令空拍逐拍一致。
- [x] `gate_equiv_sram`、`gate_equiv_requant_reset`、`gate_equiv_requant_boundary`：常规读写、异步复位取消、旧INT8捕获沿加载新配置均一致。

`CHECK_GATE_EQUIVALENCE=1`在TB中实例化镜像，镜像设置`USE_CLOCK_GATING=0`。两个实例共享所有输入；比较ready、SRAM读回、Macro数据/valid、归约转发、ACT bank、调度状态、tmp/Psum、Requant参数、raw及INT8。无效lane的保持值也比较。原有独立golden检查同时运行。

旁路模式保留各寄存器写使能。默认`USE_CLOCK_GATING=1`使用功能ICG。两种配置不增加算术流水，不改变外部协议。`PASS cluster_gate_equivalence`必须含非零比较周期数，缺少该标志不能算通过。

## 同步SRAM与逐拍表

- [x] `sram_response`与`gate_equiv_sram_response`：跨8个Macro连续读取、采样后切换Macro/行号、读转空闲/写、异步复位；sram_rd_valid及数据必须对应采样请求。
- [x] Requant无效OC四个读操作数必须为0，包括旧output Psum及变化的参数Buffer输出；有效数值向量先独立验证，覆盖保持。
- [x] 常规同步读：地址变化后、采样沿前，读数据保持；采样沿后返回新行，支持背靠背访问。`sram_rw`检查2618次写、8330次读、16种mask、复位保留及写后计算。
- [x] CIM刷新在输入接受沿读权重，同沿寄存ACT；下一沿输出Macro结果，固定1T、II=1，Hold连续刷新/复用不增加周期。
- [x] 独立Python模型核对140个Context输出、480次buffer运算和396次外部输入；[标准逐拍文档](Cluster_Timing_Tables.md)中的42组标准表、CSV及两份Word时序对应当前Slice→Context调度。标准W2/W4/W8末发射到raw分别3/4/5T，INT8再晚1T。

## 复现与证据

从`vcs-rtl/`运行`make run CASE=<用例名>`；`make regression`包含135个suite，45个正向、90个预期拒绝。用例定义在`cases.py`，`cases.mk`由其生成；波形文件带case名称后缀。

此前本地完整回归134个suite通过，其中93个为预期拒绝。九组整Cluster对照共比较292950个周期。量化单元完成40492次有效算术检查，并核对无效通道的四个操作数全部为0。

2026-10-29 新增OS1/WS1/AS8 GEMM的tensor/channel模式并统一case count命名；本轮ModelSim全量135组通过（45正向、90预期拒绝），含13个正向矩阵和九组整Cluster门控对照。AS8另检查真实表时钟、无写入保持、连续Command/计算重叠、无效Command扰动与跨行地址/参数重载；五项门控或陈旧表项故障注入均被拒绝。135个Make入口dry-run、文件列表一致性和原AS4数据逐字节检查通过。证据为 `RTL/cluster/tb/log/gemm_as8_counts_validation.log` 和 `gemm_as8_counts_sources.sha256`。

证据：`RTL/cluster/tb/log/child_consumer_validation.log`、`child_consumer_sources.sha256`、`child_consumer_unit.log`和`child_consumer_gate_equivalence.log`对应子节点消费需求门控版本；`child_consumer_audit.log`保存时序、文件列表和编译审计。源码哈希对应本轮受测RTL/TB。

覆盖为上述定向、枚举及随机数据场景，不表示穷举所有合法count和所有数据。VCS运行、工艺SRAM替换、门级时钟检查、综合与STA不由RTL功能仿真替代。跨Macro的SRAM/CIM并发访问尚未开放。

## Psum 溢出处理 TBD

- [ ] 每次tmp/Psum写入的溢出检测及拒绝、饱和或扩位策略尚未确定，也未实现对应硬件错误状态或输出valid策略。

完整功能回归覆盖满足数值边界的输入，不表示已验证超范围Psum的正确性。现有最终raw范围检查不能替代逐次写入检测；具体可复现回绕及调用方约束见[数值范围与TBD](Cluster_Requant.md)。

当前格式源码的完整回归记录为`RTL/cluster/tb/log/reformatted_validation.log`，44个SV/SVH受测文件哈希为`reformatted_sources.sha256`；与功能回归基线8c70724逐token一致。两份Word规格与本清单共同区分已验证的正常输入和仍为TBD的中间溢出策略。

## Macro ACT 精度分区门控

- [x] 三段ACT时钟与捕获/保持/异步复位：W2为512bit、W4为256bit、W8为128bit；使能来自当前输入精度。
- [x] Macro覆盖49种有序精度切换×刷新/复用，共196笔连续定向请求；高位扰动不影响未使用区的数值。
- [x] 整Cluster门控开关逐拍比较完整activation_in，覆盖七精度和OS/WS/AS。

ACT分区门控的受测源码及完整回归证据见`RTL/cluster/tb/log/act_bank_sources.sha256`与`act_bank_validation.log`，时序及结构审计见`act_bank_audit.log`。位数不变，默认ICG锁存位为684，资源口径见[主要DFF统计](Cluster_DFF_Usage.md)。

## SRAM 输出保持复用

- [x] 无独立held_weight数据寄存器，直接使用SRAM保持输出，行号/valid在每次普通读或CIM刷新沿更新。
- [x] 普通读后同地址复用、跨行后重新刷新、连续CIM刷新/复用、有效写失效及异步复位；负向case拒绝普通读换行后误用旧地址。
- [x] 端到端GEMM在预加载读回命中首行时允许首发射复用，数值、ACT与raw/INT8时序继续由独立golden核对。

SRAM输出复用专项源码与回归见`RTL/cluster/tb/log/sram_output_sources.sha256`和`sram_output_validation.log`；时序、资源及VCS入口审计见`sram_output_audit.log`。逻辑DFF名义33486bit，ICG锁存位684，SRAM读出保持模型另计8192bit。

## 共享标签和统一深度验证

共享批次描述符、三路径窄标签及tmp/Psum直接供Requant的实现通过134组完整回归（93组预期拒绝），见`shared_meta_validation.log`及`shared_meta_sources.sha256`。连续OS1/AS16、W4A4专项采用16组不同权重，确认tmp被下一个Context覆盖时，raw仍读取正确Psum槽，16个INT8结果全部匹配。

统一参数联动后，单独覆盖OUTPUT_PSUM_DEPTH=8/16/32并检查Psum、权重地址、Requant参数数组深度，三组均通过；连续AS16专项复测通过。见`shared_meta_unified_depth.log`。默认容量仍为16；统一深度及完成跟踪压缩后的当前源码通过完整134组回归，并通过逐拍模型、容量拒绝、SYNTHESIS编译/展开和9个VCS文件列表、134个Make入口检查。源码版本及验证范围见`shared_meta_provenance.log`和`shared_meta_audit_sources.sha256`。

## 完成跟踪和调度压缩验证

当前RTL/TB的受测源码为`compact_control_sources.sha256`，完整回归134组通过，包含93组准确匹配的预期拒绝，见`compact_control_validation.log`。完成位替代逐Context/lane硬件检查表，lane级完整性由独立TB检查，包括空mask、混合归约路径、七精度OS/WS/AS、WS64/AS16、OS255和异步复位。

`compact_control_baseline_equivalence.log`记录修改前后RTL共47267拍比较，覆盖mixed_context、oc_merge、requant_buffers、requant_boundary。ready、batch_active关闭周期、issue及raw/INT8和存储内容一致。门控/旁路镜像的九组验证包含在完整回归内。

`compact_control_dff_audit.log`以独立TB的$bits展开深度8/16/32，默认名义DFF33486bit，ICG锁存位684。逐拍时序及SYNTHESIS编译/展开、9个VCS文件列表和134个Make入口检查见`compact_control_audit.log`。没有执行实际VCS仿真或工艺综合/STA。

shift接口、存储及运算支持完整INT10；完整编码域证据见下文。

## 组合共享验证

受测源码见`comb_share_sources.sha256`，完整回归134组通过（93组预期拒绝），见`comb_share_validation.log`。TB逐OC检查fusion/acc请求互斥及空闲共享加法器操作数隔离。独立golden、逐拍历史、物理输出lane、mask和提前门控检查继续运行。

修改前后RTL在mixed_context、oc_merge、requant_buffers、requant_boundary、input_overlap、context_stress六组专项共128617拍比较一致。比较ready、batch结束周期、raw/INT8、tmp/Psum及算术写回数据，并逐节点比较归约OC门控请求，见`comb_share_baseline_equivalence.log`。直接量化单测显式驱动统一group_sel_i，覆盖高位置组、OC0屏蔽、空mask、两种scale模式和逐OC参数。

`comb_share_audit.log`记录140个Context延迟、480个Buffer操作及396个外部输入事件的独立模型核对，并检查SYNTHESIS编译/展开、9个VCS文件列表和134个Make入口。`comb_share_dff_audit.log`确认深度8/16/32的资源展开值保持，默认名义DFF33486bit，ICG锁存位684。未执行实际VCS仿真、工艺综合或STA，不能据此断言实际面积收益或时序收敛。

MacroSliceFusion及SingleMacro与组合共享前版本逐字节一致。Requant保留INT10接口和存储，完整INT10编码域由独立Python向量和Context专项验证。

## 当前空批次与完整 INT10 验证

此前完整回归为133组，包含90组准确匹配的预期拒绝。源码哈希和结果见`fix_empty_int10_sources.sha256`、`fix_empty_int10_validation.log`；前文其他文件名对应各专项的源码快照。

- `requant_unit`：17908个整数向量、512个四通道向量，共73680次数值核对；覆盖全部1024种INT10编码、零乘积、极值ZP和右移63位半值。
- `requant_full_shift`：77组七精度Context测试，2912个raw和2912个INT8比对，包含OS1/OS2、稀疏OC、两种scale模式及接收/发射重叠。
- `requant_empty_batch`：七精度空批次后最早加载下一批次，8次有效输出，逐捕获沿检查tmp开钟请求与消费相等。独立专项覆盖父节点屏蔽的七组空批次；将事务valid恢复为无条件issue时，检查器准确拒绝误开钟。

输出仍为raw后1T的寄存INT8；没有增加流水级或DFF。时序模型、SYNTHESIS条件编译/展开和VCS文件列表/Make入口审计见`fix_empty_int10_audit.log`，并不代替工艺综合或STA。Psum中间溢出策略和未知result mask断言缺口仍待处理。

## Per-tensor ZP外移与整个ZP buffer关钟（2026-10-28）

此前版本通过ModelSim完整133组用例（90组准确匹配的预期拒绝），最终全量运行无失败。11个正向GEMM逐元素检查CIM INT8值和TB修正结果；per-channel六个矩阵场景的原数值/输入文件与修改前逐字节一致。

per-tensor AS Context和批次ZP的实际门控时钟必须为0，全部ZP槽位保持；异步复位仍有效。共享scale照常更新，per-channel仍按原公式工作。Context专项覆盖mode切换、后续Tile将未使用ZP改为X以及门控/旁路逐拍等价。量化单元17908个标量向量分别检查两种模式，512个四通道向量，共145312次数值检查，另检查TB修正的扩位加法和再次饱和。

隔离副本将两组ZP时钟故意接回仍活动的共享时钟，实际时钟检查器准确触发`Per-tensor zero-point buffer clock is not fully gated`，证明仅禁止写入无法通过该检查。

`gemm_os1_ws8_as1_w4a16_high_group_tensor`与原单次饱和算法最大差值为9，已接受并记录于metadata；原算法参考不作为新流程的通过条件。其余已有GEMM示例中的差值见各自metadata。

证据：[本轮验证记录](../RTL/cluster/tb/log/per_tensor_zp_validation.log)与`per_tensor_zp_sources.sha256`。10个顶层普通及SYNTHESIS条件编译通过；未执行实际VCS、工艺综合或STA。

## 9bit count 扩宽验证 2026年10月30日

cim_os_cnt、cim_ws_cnt、cim_as_cnt均为9bit，合法编码1～511，cluster_ctrl_t共110bit。Tile状态和窄流水标签kt同步扩为9bit；TB赋值转换、描述符宽度检查、ACT参考数组和范围检查同步更新。

ModelSim的11个目标编译通过；默认Cluster回归200组配置、1368个case通过。OS255/256/511覆盖W2A4/W2A8、signed/unsigned、单Context/WS2/AS2，共36个非零算术场景通过。AS256和AS511在默认容量下准确触发CLUSTER_CONTEXT_CAPACITY，避免高位截断后进入错误调度。容量上限仍由MAX_CONTEXTS及各buffer深度决定，编码扩宽不增加默认存储容量。未运行实际VCS、工艺综合或STA。
