# Cluster 验证清单

本清单对应当前RTL、TB及VCS用例目录。检查功能结果、周期和实际门控行为；物理SRAM IP、综合后门控结构及STA由集成流程验证。

## 调度与容量

- [x] 七种精度、UINT/INT、OS1/2、Single/WS/AS、有无命令空拍：`cluster_default`、`input_overlap`、`requant_channel`。检查输入寄存后一拍发射、Slice/Context/Tile顺序及输出周期。
- [x] AS16正向：`context_stress`、`requant_buffers`，覆盖OS1/2。OS1 WS64及OS2 WS8/AS8分别检查，Context之间不串数据。
- [x] AS17、AS64拒绝：七精度×两种符号×OS1/2，必须命中`CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。地址、标签、参数深度不足分别匹配对应诊断。

所有AS采用Tile→Slice→Context，默认最多16个Context。Psum使用条件为`cim_os_cnt>1 || (cim_as_cnt>1 && act_bits>4)`，每OC最多一个Context项在同一沿写入，高地址项整批关钟。

## Context量化参数与OC映射

- [x] `requant_context`：OS1/2、两种scale模式；不同Context的multiplier、shift、ZP均不同，32个INT8值与独立整数预期比对。
- [x] `requant_buffers`：七精度、AS8/AS16、OS1/2，两种scale模式，77个case及2912个raw、2912个INT8比对。Context shift按编号变化，首Tile加载、后续Tile校验、最终结果按Context取参数。
- [x] `requant_channel`与GEMM：16种OC mask、七种对齐组、高位置物理lane、N尾部；参数c固定对应OC c。
- [x] Per-tensor在OC0被屏蔽时仍取当前Context的第0项scale；未使用的三组scale/shift寄存器保持，四项ZP按本地OC索引。

## A4地址旁路与接收发射重叠

- [x] `requant_a4_address_bypass`：`WGT_RADDR_BUFFER_DEPTH=1`，22个A4 case，832个raw及832个INT8比对；权重深表时钟关闭，Requant固定Context表正常保留参数。
- [x] `input_overlap`：168个case，检查ACT尾部采样/地址接收与已有输入发射重叠，当前地址未到达时暂停并正确恢复。
- [x] `requant_buffers`：每个case必须在Context命令尚未收齐时已经发射，否则报告`AS waited for all Context parameters before issuing`。

## 门控与逐拍一致性

- [x] 子节点消费需求：`reduce_tree`用独立祖先路径模型核对两层转发门控；整Cluster检查Macro结果需求在输入沿寄存、被屏蔽子节点的实际时钟和输出保持，以及两侧关钟时父节点加法器输入/和保持。独立终点继续与数值golden及原时序比对。两层分别覆盖39次pair、5次四Macro本地有效而祖先屏蔽的转发关钟；额外42651周期检查计算数据路径使能从前一沿建立后保持到捕获沿。
- [x] 实际脉冲及保持：Macro计算/SRAM/Hold三个域、Macro逐OC结果、归约树逐节点/OC、tmp/Psum、raw/INT8逐lane、Context参数组均由检查器验证。
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
- [x] 独立Python模型核对140个Context输出、480次buffer运算和396次外部输入；根README的42组标准表、CSV及两份Word时序对应当前Slice→Context调度。标准W2/W4/W8末发射到raw分别3/4/5T，INT8再晚1T。

## 复现与证据

从`vcs-rtl/`运行`make run CASE=<用例名>`；`make regression`包含134个suite，41个正向、93个预期拒绝。用例定义在`cases.py`，`cases.mk`由其生成；波形文件带case名称后缀。

本地完整回归134个suite通过，其中93个为预期拒绝。九组整Cluster对照共比较292941个周期。量化单元完成40492次有效算术检查，并核对无效通道的四个操作数全部为0。

证据：`RTL/cluster/tb/log/child_consumer_validation.log`、`child_consumer_sources.sha256`、`child_consumer_unit.log`和`child_consumer_gate_equivalence.log`对应子节点消费需求门控版本；`child_consumer_audit.log`保存时序、文件列表和编译审计。源码哈希对应本轮受测RTL/TB。

覆盖为上述定向、枚举及随机数据场景，不表示穷举所有合法count和所有数据。VCS运行、工艺SRAM替换、门级时钟检查、综合与STA不由RTL功能仿真替代。跨Macro的SRAM/CIM并发访问尚未开放。
