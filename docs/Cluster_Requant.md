# 四通道 Requant

Cluster内部保存raw signed32，正式结果由Requant端口输出。Requant使用四个组合算术通道；参数c固定对应归约结果的OC c，与 oc_mask 中OC0、OC1、OC2、OC3的位序一一对应。屏蔽OC1不会把参数1挪给OC2。

正式端口为 `cluster_top.requant_data_o[255:0]` 和 `requant_valid_o[31:0]`。`psum_data_o/out_valid_o`不是RTL端口；它们仅是TB层次观察内部 `raw_data/raw_valid` 时使用的别名。

## 数据通路和限制

内部raw Psum寄存器 → 四通道组合Requant → INT8输出寄存器。量化valid严格比对应raw valid晚一拍，没有内部算术流水、FIFO或反压。仅全部slice和OS Tile完成后的最终raw量化一次；不改变tmp/Psum历史。无valid的lane保持，复位清零并取消待输出结果。

reset 高有效、异步置位，INT8 数据与 valid 均不等待时钟边沿清零；两个上升沿之间的短复位脉冲也清除输出和待发布结果。释放由上游同步并满足恢复/移除时序。

启用Requant时，无论per-tensor还是per-channel scale，均只允许一个对齐的Macro归约组、最多4个OC：

- W8：Macro0～7全归约，EN=0xff。
- W4：Macro0～3或Macro4～7中的一组，EN=0x0f或0xf0。
- W2：Macro0～1、2～3、4～5、6～7中的一组，EN=0x03、0x0c、0x30或0xc0。

cim_reduce_split_mask必须使所选组完整归约；不属于该组的Macro不参与计算。OC可部分屏蔽或全部屏蔽。K尾部不足时由激励/权重补零，不能靠另开一个N组突破Requant限制。

物理lane位置继续采用现有归约树定义。四个算术通道从有效组收集OC0～3，结果散射回原lane位置；输出端口仍为32×8bit数据和32bit valid，但每拍最多4个lane有效，不将高组的结果强行搬到低4lane。

参考实现参数ENABLE_REQUANT默认1，启用上述检查。设置0用于raw-only归约树验证，保留raw行为，INT8 valid保持0。tb_Cluster默认0；Python量化专项覆盖为1。该开关由编译参数配置。

## 参数与固定OC顺序

requant_cfg_t共298bit：conv_mode1 + requant_mode1 + 4×INT32 multiplier + 4×INT10 shift + 4×INT32 zp。compute descriptor 为107 bit。

- requant_multiplier[32*c+:32]：OC c的signed INT32乘数，四项共128bit。
- requant_shift[10*c+:10]：OC c的signed INT10移位，四项共40bit；当前有效配置为−31～31。
- requant_zp[32*c+:32]：OC c的signed INT32有效偏置，四项共128bit。
- requant_mode=0：四个OC共用multiplier/shift的第0项，其余三项不参与算术；zp仍分别使用四项。
- requant_mode=1：四个OC分别使用自己的multiplier/shift，要求conv_mode=1。conv_mode表示普通卷积模式；统一的单组/4OC限制也适用于mode=0。

不需要OC选择字段。组位置由descriptor给出，OC c使用组最左Macro的cim_macro_oc_mask[4*first+c]决定有效性，现有各层merge mask继续影响贡献。参数c始终对应本地OC c，不按有效位数量重新编号。

例如W4选Macro4～7，split=0x01，结果位于物理lane4～7：参数0对应lane4/OC0，参数1对应lane5/OC1；若OC1被屏蔽，lane6仍使用参数2。zp也遵循完全相同的索引。

## 合并后的zero-point

输入offset补偿已由参数生成端合入有效zp。合并后的zp仍是per-weight-output-channel，即使weight使用per-tensor scale，zp也不能因此退化成一个公共值。Cluster只接收这四个zp，没有独立psum_correction字段、加法或缓存。

数值公式为q[n]=clip_INT8(round(raw[n]×multiplier[c]×2^shift[c])+zp[c])；per-tensor时multiplier/shift均选择第0项。multiplier没有隐含Q31除法。最近整数舍入，半整数远离零；zp在round后、最终clip前加入，只在最后饱和到−128～127。

参数生成示例：zp[n]=output_zp_reference[n]+round((-ACT_zp×sum(Wq[:,n]))×effective_scale[n])。Python分别保存raw整数接口golden、中心化数学参考和实数参考，并记录融合zp时的舍入差异；RTL须与接口golden逐元素完全一致。

## 锁存和AS Context

`REQUANT_CONTEXT_DEPTH=OUTPUT_BUFFER_DEPTH`，默认16。非AS使用一组批次配置，两个Context深表均关闭；WS在整批内复用同一配置。所有多Context AS，包括A4，使用固定Context参数槽位，cim_as_cnt不得大于16；表项在批次内不回收，没有FIFO。

首K Tile各Context命令加载参数，后续K Tile重复并校验有效参数一致，mode/conv_mode整批不变。地址、参数和ACT接收可与已有输入的发射重叠，不等待所有参数收齐。raw的Context标签选择对应参数，量化消费不会释放表项。

每项完整配置为4×INT32 multiplier、4×INT10 shift、4×INT32 zp，共296bit；16项为4736bit/592B，不含valid及公共控制。mode0每个Context只更新第0项scale并广播，另外三项scale/shift关闭时钟；不同Context仍可有不同的共享scale。mode1更新四组scale。两种模式都保存四个逐通道zp。

参数深表整批门控，不做逐地址ICG；非AS批次配置仅在加载时打开时钟。raw和INT8输出数据按lane有效事件独立门控，valid保持主时钟清零。测试可将参数深度覆盖为1或2，AS4必须报告容量错误。

最后raw后的下一沿可同时捕获旧INT8和接受新batch配置，旧结果使用沿前旧参数。输出valid、保持和复位规则不变。配置未知、shift越界、分组违规、Context容量不足或跨Tile参数不一致时，仿真必须命中准确诊断。

## Psum 数值范围与溢出限制

tmp 和 Psum 均为 signed32 存储。组合运算使用更宽中间值，但写入32bit寄存器时会截断；目前没有中间溢出标志、饱和或自动扩位。最终结果发布时的范围检查只检查当拍运算，无法发现此前已经回绕的历史。

可复现场景：W8A16、有符号、每个K Tile覆盖256项、OS5，全部ACT=32767、weight=127。真实累加值为5326603520，超过signed32；中间Psum截断后，最终raw为1031636224，仍落在signed32范围，最终检查不会报错。multiplier=1、shift=−26、zp=0时输出15；若用宽位累加后再量化，数学参考为79。当前signed32接口不保证这个超范围场景的结果。

调用方须保证每次写入tmp/Psum的中间值都在−2147483648～2147483647内，不能只检查最终数学和。Requant末端INT8 clip不能补偿此前的Psum回绕；溢出的拒绝、饱和或扩位策略尚未定义。

## 测试与运行

- tb_ClusterRequant.sv：9611个原始整数向量，以及512个独立四通道Python向量；覆盖两种scale模式、不同参数、16种OC mask及高位置输出组。
- +REQUANT_TEST：168个per-tensor集成case；+REQUANT_CHANNEL_TEST：1536个per-channel case，覆盖七精度、所有可选Macro组、16种mask、OS1/2和Single/WS/AS。
- +CONTEXT_BUFFER_TEST：77个固定槽位case，2912个raw和2912个INT8检查；七精度、两种scale模式及参数接收/发射重叠。A4专项用地址深度1验证旁路。
- +REQUANT_CONTEXT_TEST：OS1/OS2与两种scale模式，4个串行批次、32个输出，检查不同Context的独立multiplier/shift/zp映射。
- 独立验证量化valid晚1T、数据保持、复位取消、无时钟边沿的短异步复位和最早批次配置切换。
- 两个GEMM TB均运行per-tensor weight与per-channel weight版本，每版精确检查512个raw和512个INT8；OS2/AS4另查4096次Psum历史。
- 所有case开始打印英文时间戳和描述；负向检查包括非conv的per-channel配置、单组限制、shift、未知值、AS参数深度及跨Tile scale/zp变化。

仿真使用 [VCS case 入口](../vcs-rtl/README.md)，支持独立编译、数据生成、运行及结果检查。

计算OC mask关闭对应Macro结果、归约转发、tmp/Psum及raw/INT8数据寄存器时钟；对应组合算术操作数隔离。门控按已对齐事务标签生效。公共ACT入口、SRAM整行访问和完整行Hold为其他有效OC保留工作能力。

两种scale模式均以不同Context的独立shift验证参数选择；完整Cluster门控开关逐拍比较见[验证清单](Cluster_Verification.md)。

## 无效OC的两个读源

output Psum寄存器和Requant Context参数存储在无写入时保持，不清零旧内容。进入每个Requant算术通道前，按对齐后的raw valid隔离Psum、multiplier、shift和ZP四个操作数；该OC无有效输入时四项都为0。Per-tensor共享scale仍供其他有效OC使用，仅屏蔽目标OC的读分支。

组合单元的无效物理lane数据为0；最终INT8输出寄存器仍由lane valid门控，保留旧值。单元测试先以有效输入验证全部数值向量，再检查mask隔离，避免无效通道零输出掩盖数值覆盖。

归约树将父节点的消费需求向下传递到子节点输出寄存器。Macro结果的需求在输入沿寄存，下一沿控制逐OC结果时钟；归约转发需求仍提前一拍寄存。条件包含从子节点到所属终点的全部合并mask，父节点不消费时，相关子节点输出保持原值，从而保持父节点加法器输入。独立终点tap保留自己的有效数据路径，不因其他组被屏蔽而关闭。此路径不加入强制置零隔离或数据流水，输出延迟保持原定义。

门控作用于子节点输出寄存器；共享ACT、完整行SRAM/Hold及Macro结果寄存器前的组合乘法不因此保证停止翻转。事务配置切换引起的控制翻转与持续数据翻转分开验证。
