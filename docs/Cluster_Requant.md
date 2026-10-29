# 四通道 Requant

Cluster内部保存raw signed32，正式结果由Requant端口输出。Requant使用四个组合算术通道；参数c固定对应归约结果的OC c，与 oc_mask 中OC0、OC1、OC2、OC3的位序一一对应。屏蔽OC1不会把参数1挪给OC2。

正式端口为 `cluster_top.requant_data_o[255:0]` 和 `requant_valid_o[31:0]`。`psum_data_o/out_valid_o`不是RTL端口；它们仅是TB层次观察内部 `raw_data/raw_valid` 时使用的别名。

## 数据通路和限制

tmp/Psum存储的raw视图 → 四通道组合Requant → INT8输出寄存器。raw没有独立的数据寄存器，仅raw valid为发布事件；raw仅在valid时有观察合同。量化valid严格比对应raw valid晚一拍，没有内部算术流水、FIFO或反压。仅全部slice和OS Tile完成后的最终raw量化一次；不改变tmp/Psum历史。无valid的lane保持，复位清零并取消待输出结果。

reset 高有效、异步置位，INT8 数据与 valid 均不等待时钟边沿清零；两个上升沿之间的短复位脉冲也清除输出和待发布结果。释放由上游同步并满足恢复/移除时序。

启用Requant时，无论per-tensor还是per-channel scale，均只允许一个对齐的Macro归约组、最多4个OC：

- W8：Macro0～7全归约，EN=0xff。
- W4：Macro0～3或Macro4～7中的一组，EN=0x0f或0xf0。
- W2：Macro0～1、2～3、4～5、6～7中的一组，EN=0x03、0x0c、0x30或0xc0。

cim_reduce_split_mask必须使所选组完整归约；不属于该组的Macro不参与计算。OC可部分屏蔽或全部屏蔽。K尾部不足时由激励/权重补零，不能靠另开一个N组突破Requant限制。

物理lane位置继续采用现有归约树定义。四个算术通道从有效组收集OC0～3，结果散射回原lane位置；输出端口仍为32×8bit数据和32bit valid，但每拍最多4个lane有效，不将高组的结果强行搬到低4lane。

参考实现参数ENABLE_REQUANT默认1，启用上述检查。设置0用于raw-only归约树验证，保留raw行为，INT8 valid保持0。tb_Cluster默认0；Python量化专项覆盖为1。该开关由编译参数配置。

## 参数与固定OC顺序

requant_cfg_t共297bit：conv_mode1 + 4×INT32 multiplier + 4×INT10 shift + 4×INT32 zp。compute descriptor 为107 bit。

- requant_multiplier[32*c+:32]：OC c的signed INT32乘数，四项共128bit。
- requant_shift[10*c+:10]：OC c的signed INT10移位，四项共40bit；当前有效配置为−512～511。
- requant_zp[32*c+:32]：OC c的signed INT32有效偏置，四项共128bit，仅mode=1使用。mode=0保留兼容字段，但忽略其值（包括X）、不加载ZP存储、不检查跨Tile的ZP一致性。
- conv_mode=0：weight采用per-tensor量化，四个OC共用multiplier/shift的第0项，其余三项不参与算术；不加载或消费zp，输出为未加ZP的饱和INT8。逐channel ZP仅由TB在输出之后修正。
- conv_mode=1：weight采用per-channel量化，四个OC分别使用自己的multiplier/shift，ZP在RTL内、饱和前相加。conv_mode仅选择weight量化模式；统一的单组/4OC限制也适用于mode=0。

不需要OC选择字段。组位置由descriptor给出，OC c使用组最左Macro的cim_macro_oc_mask[4*first+c]决定有效性，现有各层merge mask继续影响贡献。参数c始终对应本地OC c，不按有效位数量重新编号。

例如W4选Macro4～7，split=0x01，结果位于物理lane4～7：参数0对应lane4/OC0，参数1对应lane5/OC1；若OC1被屏蔽，lane6仍使用参数2。zp也遵循完全相同的索引。

## 合并后的zero-point

输入offset补偿由参数生成端合入有效ZP，ZP_n仍逐输出channel生成。两种模式的计算边界不同：

- **per-tensor / mode=0，CIM输出**：`r[n]=clip_INT8(round(raw[n]×multiplier[0]×2^shift[0]))`。
- **per-tensor，TB修正**：`q[n]=clip_INT8(signed(r[n])+ZP_n)`。TB先扩位再加signed INT32 ZP，最后饱和，不能用8bit加法导致回绕。
- **per-channel / mode=1，保持原逻辑**：`q[n]=clip_INT8(round(raw[n]×multiplier[c]×2^shift[c])+zp[c])`，ZP仍在CIM内、饱和前相加。

multiplier没有隐含Q31除法。舍入采用最近整数、半整数远离零。两种模式均保持原INT8端口、valid和raw后1T输出时序。

参数生成示例：`ZP_n=output_zp_reference[n]+round((-ACT_zp×sum(Wq[:,n]))×effective_scale[n])`。per-tensor GEMM驱动不将该ZP传入CIM，只在TB按逻辑列n修正；高位置归约组、N尾块、OC mask空洞和AS Context均按实际channel映射。

per-tensor接受两次饱和导致的算法差异。例如未饱和值200、ZP=-100：CIM先输出127，TB修正为27；原来只在加ZP后饱和的算法得到100。不能要求新流程与原参考仅相差1 LSB。

Python独立生成`cim_golden.hex`（CIM端口值）、`quant_golden.hex`（TB修正后的值）和`original_quant_reference.hex`（原单次饱和算法）。TB先精确检查CIM值，再检查修正结果；CSV中的quant为修正结果。metadata的`original_algorithm_max_difference`记录与原算法的最大差异，原参考不作为新流程的通过条件。per-channel的新旧golden应完全一致。

## 已舍入 INT32 ZP 与当前计算合同

令`R(x)`为最近整数舍入、半整数远离零，`C(x)=min(127,max(-128,x))`。最终raw为全部Slice及OS Tile完成后的signed32整数；`S_hat=multiplier×2^shift`，没有隐含Q31除法，shift覆盖signed INT10的−512～511。

对输出channel n，`C_n=sum_k(Wq[k,n])`，当前GEMM参数生成示例为`ZP_n=Z_y_reference[n]+R((-ACT_zp×C_n)×S_hat_n)`。**per-tensor TB使用的ZP_n与per-channel RTL使用的ZP_c都已在生成端round，并保存为signed INT32整数**；它们属于输出量化域，不是未舍入小数，也不是累加器域`D_n=-ACT_zp×C_n`。ZP不提前clip到INT8。per-tensor即使共享scale，ZP仍因各列weight sum不同而逐channel生成。

- per-tensor RTL：`CIM_out[n]=C(R(raw[n]×multiplier[0]×2^shift[0]))`，不加ZP。整个AS Context和批次ZP buffer关钟，scale第0项仍正常工作；异步reset有效。
- per-tensor TB：`TB_out[n]=C(signed(CIM_out[n])+ZP_n)`，用longint signed符号扩位后相加，再饱和；**此步不再round**。这是CIM先饱和、TB修正后再饱和的两阶段流程。
- per-channel RTL：`CIM_out[n]=C(R(raw[n]×multiplier[c]×2^shift[c])+ZP_c)`，先round，再加INT32 ZP，最后饱和。TB直接比较该输出，不重复加ZP。

当前保留ZP在round外。半整数远离零并不对所有整数平移保持一致，例如`R(-0.5)+1=0`而`R(-0.5+1)=1`；不能以ZP为整数为由改写运算顺序并宣称逐bit等价。将尚未round的小数补偿移入round、或先计算`raw+D`再缩放，属于另外的数值合同，当前未采用。

参数选择随输出Context对齐，参数c固定对应本地OC c；TB按实际逻辑列n修正，覆盖高位置组、AS、N尾部和mask空洞。输出INT8与valid仍比raw晚1T，TB补偿不增加RTL流水级。

参考C++的`FixedPointMultiplier`采用`scale=M×2^(e−31)`，而当前RTL采用`scale=M×2^h`；适配必须使用`h=e−31`，不能直接复制参考shift。代码中的Q0.31归一化、极小值归零及指数钳制仅是参考参数生成策略，不限制当前RTL完整INT10编码。详细数学展开及原始代码参考已合入[Block Spec](CIM_Block_Spec.docx)第6.2节。

## 锁存和AS Context

`REQUANT_CONTEXT_DEPTH=OUTPUT_BUFFER_DEPTH`，默认16。非AS使用一组批次配置，两个Context深表均关闭；WS在整批内复用同一配置。所有多Context AS，包括A4，使用固定Context参数槽位，cim_as_cnt不得大于16；表项在批次内不回收，没有FIFO。

首K Tile各Context命令加载有效参数，后续K Tile重复并校验有效参数一致（mode0仅scale，mode1为scale及ZP），conv_mode整批不变。地址、参数和ACT接收可与已有输入的发射重叠，不等待所有参数收齐。raw的Context标签选择对应参数，量化消费不会释放表项。

每项完整配置为4×INT32 multiplier、4×INT10 shift、4×INT32 zp，共296bit；16项为4736bit/592B，不含valid及公共控制。mode0每个Context只更新第0项scale并广播，另外三项scale/shift关闭时钟；不同Context仍可有不同的共享scale。mode1更新四组scale。仅mode1保存四个逐通道zp；mode0不更新这些寄存器，不使用上一个per-channel批次留下的值。兼容存储容量仍保留，不能将运行时禁用等同于物理移除寄存器。

参数深表整批门控，不做逐地址ICG；非AS批次配置仅在加载时打开时钟。tmp/Psum和INT8输出数据按lane有效事件独立门控，valid保持主时钟清零。测试可将参数深度覆盖为1或2，AS4必须报告容量错误。

最后raw后的下一沿可同时捕获旧INT8和接受新batch配置，旧结果使用沿前旧参数。输出valid、保持和复位规则不变。配置未知、分组违规、Context容量不足或跨Tile参数不一致时，仿真必须命中准确诊断。

## Psum 数值范围与溢出处理 TBD

当前实现：tmp_result与Psum[ctx]均为signed32存储；fusion、acc等组合中间值使用signed64（longint signed），但写入32bit寄存器时截断为低32bit。当前没有逐次写入的溢出标志、饱和、自动扩位或硬件错误状态。

检查范围：仅在result_done发布最终raw时，仿真检查当拍arithmetic_result是否在signed32范围内；UINT还检查非负。此前tmp/Psum若已截断回绕，后续值可能重新落入范围，因此最终检查不等于端到端溢出检测；valid只表示事务发布，不保证此前没有溢出。

可复现边界：W8A16、INT、每Tile K256、OS5，ACT全为32767、weight全为127。数学累加5326603520；中间signed32回绕后raw可为1031636224，最终范围检查不报错。multiplier=1、shift=-26、zp=0时INT8为15，宽位累加后量化参考为79。此例描述当前限制，不属于合法范围内的数值正确性保证。

TBD：逐次写入的检测位置、溢出后的拒绝或终止、饱和或扩位策略，以及错误状态与输出valid处理均未确定、未实现。后续决策须同时覆盖WS/单Context的tmp bit fusion、AS的逐Context Psum fusion和OS跨Tile累加；扩大Context深度不能解决数值位宽溢出。

当前集成约束：调用方必须保证每次tmp/Psum写入值均在-2147483648～2147483647内，UINT还须非负，不能只保证最终数学和不溢出。Requant末端INT8 clip无法修复先前回绕。cim_os_cnt的8bit/255编码上限与安全累加次数是两类约束。

## 测试与运行

- tb_ClusterRequant.sv：17908个原始整数向量，以及512个独立四通道Python向量；覆盖两种scale模式、不同参数、16种OC mask及高位置输出组。
- +REQUANT_TEST：168个per-tensor集成case；+REQUANT_CHANNEL_TEST：1536个per-channel case，覆盖七精度、所有可选Macro组、16种mask、OS1/2和Single/WS/AS。
- +CONTEXT_BUFFER_TEST：77个固定槽位case，2912个raw和2912个INT8检查；七精度、两种scale模式及参数接收/发射重叠。A4专项用地址深度1验证旁路。
- +REQUANT_CONTEXT_TEST：OS1/OS2与两种scale模式，4个串行批次、32个输出，检查不同Context的独立multiplier/shift/zp映射。
- 独立验证量化valid晚1T、数据保持、复位取消、无时钟边沿的短异步复位和最早批次配置切换。
- 两个GEMM TB均运行per-tensor weight与per-channel weight版本，每版精确检查512个raw和512个INT8；OS2/AS4另查4096次Psum历史。
- 所有case开始打印英文时间戳和描述；负向检查包括未知conv_mode配置、单组限制、未知值、AS参数深度及跨Tile scale/zp变化。

仿真使用 [VCS case 入口](../vcs-rtl/README.md)，支持独立编译、数据生成、运行及结果检查。

计算OC mask关闭对应Macro结果、归约转发、tmp/Psum及tmp/Psum和INT8数据寄存器时钟；对应组合算术操作数隔离。门控按已对齐事务标签生效。公共ACT入口、SRAM整行访问和完整行Hold为其他有效OC保留工作能力。

两种scale模式均以不同Context的独立shift验证参数选择；完整Cluster门控开关逐拍比较见[验证清单](Cluster_Verification.md)。

## 无效OC的两个读源

output Psum寄存器和Requant Context参数存储在无写入时保持，不清零旧内容。进入每个Requant算术通道前，按对齐后的raw valid隔离Psum、multiplier、shift和ZP四个操作数；该OC无有效输入时四项都为0。Per-tensor共享scale仍供其他有效OC使用，仅屏蔽目标OC的读分支。

组合单元的无效物理lane数据为0；最终INT8输出寄存器仍由lane valid门控，保留旧值。单元测试先以有效输入验证全部数值向量，再检查mask隔离，避免无效通道零输出掩盖数值覆盖。

归约树将父节点的消费需求向下传递到子节点输出寄存器。Macro结果的需求在输入沿寄存，下一沿控制逐OC结果时钟；归约转发需求仍提前一拍寄存。条件包含从子节点到所属终点的全部合并mask，父节点不消费时，相关子节点输出保持原值，从而保持父节点加法器输入。独立终点tap保留自己的有效数据路径，不因其他组被屏蔽而关闭。此路径不加入强制置零隔离或数据流水，输出延迟保持原定义。

门控作用于子节点输出寄存器；共享ACT、SRAM保持输出及Macro结果寄存器前的组合乘法不因此保证停止翻转。事务配置切换引起的控制翻转与持续数据翻转分开验证。

## 共享事务标签与结果存储

批次描述符由整个 Cluster 共享。四级流水仅携带 valid、Slice、Context 和 K Tile；tmp 标签按 2/4/8 Macro 三种归约延迟路径共享，lane 通过批次的归约配置选择路径。默认 Context 宽6bit，每个窄标签17bit；四级流水68bit、三路径 tmp 标签51bit，逐lane tmp valid另32bit。三路径 raw Context 指针共18bit。逐lane兼容视图为组合连线，不复制配置寄存器。

Psum 使用条件为 `cim_os_cnt>1 || cim_as_cnt>1`。OS1/AS2～16（含 A4）按 Context 保存结果；深度16允许AS16，AS17/AS64拒绝。AS的 Tile→Slice→Context 发射顺序以及包内接收/发射重叠保持。A4仅旁路深权重地址表，Requant Context 参数仍须保留至消费。

raw 数据直接选择对应 Context 的 Psum 或单 Context/WS 的 tmp，不另设1024bit raw DFF。raw valid 保持原发布时刻，INT8 输出寄存器及 valid 仍晚1T。无效周期 raw 视图可能变化；正式 INT8 输出在无 valid 时保持。各路径指针和标签按提前门控请求更新。

## 共享组和Context选择

ClusterRequant的内部输入group_sel_i为3bit物理归约组编号，由Cluster的批次配置解码生成。valid_i只能标记该组的有效OC；四个通道按4×group_sel_i+c直接选取原始物理lane，不分别扫描优先级链。OC c始终对应参数c，mask不压紧编号。OC0被mask以及全部OC被mask时，组编号仍由配置确定。

AS四通道共享该组归约路径的raw Context指针，统一寻址Requant Context表。per-channel各OC按自身valid选取ZP及scale；per-tensor各OC的ZP读操作数固定为0，per-tensor的scale始终读取当前Context的OC参数槽0，不依赖OC0 valid。每个算术通道入口的Psum、multiplier、INT10 shift及ZP隔离和输出寄存器门控保持独立。

该共享仅用于合法单组Requant。raw-only多组归约仍保留32lane存储及三个不同延迟路径；当前Psum计算读地址和上一Context的Requant读取地址不能合并。INT10接口及存储位宽保持；完整INT10移位运算范围的修复不属于组合共享改动。

## INT10 运算与边界测试

全部 signed INT10 编码 −512～511 均有效；寄存位宽仍为10 bit。乘积为完整 signed64，普通范围内在扩展位宽后移位，以下ZP相加及相消边界仅适用于per-channel；per-tensor在CIM内将ZP操作数固定为0，TB于INT8饱和后修正。

- 左移0～31：保留扩展乘积及ZP相消能力，包括 shift=31、ZP=INT32_MIN 的相消边界。
- 左移32～511：非零整数乘积无法被任何INT32 ZP抵消到INT8范围，直接按乘积符号饱和；乘积为0时仍按ZP输出。
- 右移1～63：按绝对值舍入，半值远离零，再恢复符号。右移63位时最大乘积2^62恰为半值，必须保留输出1。
- 右移64～512：INT32乘积的绝对值不超过2^62，舍入结果为0，再加入ZP并饱和。

这些范围判定保持公式的精确整数结果，不扩展移位寄存器，不改变一级组合逻辑及INT8输出寄存器的1T延迟。Python任意精度golden覆盖全部1024种shift编码、正负及零乘积、极值ZP和半值边界；SV集成参考模型使用576位整数，与RTL的范围分支实现独立。

`requant_full_shift`检查七种精度、OS1/OS2、两种scale模式、AS Context独立参数和屏蔽OC；`requant_empty_batch`检查七精度空批次与有效批次的最早连续接收。VCS入口和FSDB名称由相同case目录管理。

Per-tensor整个zero-point buffer关钟：AS Context ZP使用`deep_zp_clock`（复用现有`channel_scale_clock`门控域），批次ZP使用`batch_zp_clock`（复用`batch_channel_clock`）。mode=0两者均无时钟脉冲；共享第0项scale仍使用自己的时钟，不受影响。mode=1维持原ZP加载、保持和算术结果；异步复位仍有效。不新增ICG或修改配置容量。TB检查实际ZP时钟电平及存储保持，门控/旁路镜像继续逐拍对照。
