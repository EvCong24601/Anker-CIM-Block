# 四通道 Requant

Cluster保留raw signed32输出。Requant使用四个组合算术通道；参数c固定对应归约结果的OC c，与原有oc_mask中OC0、OC1、OC2、OC3的位序一一对应。屏蔽OC1不会把参数1挪给OC2。

## 数据通路和限制

raw Psum输出寄存器 → 四通道组合Requant → INT8输出寄存器。量化valid严格比对应raw valid晚一拍，没有内部算术流水、FIFO或反压。仅全部slice和OS Tile完成后的最终raw量化一次；不改变tmp/Psum历史。无valid的lane保持，复位清零并取消待输出结果。

启用Requant时，无论per-tensor还是per-channel scale，均只允许一个对齐的Macro归约组、最多4个OC：

- W8：Macro0～7全归约，EN=0xff。
- W4：Macro0～3或Macro4～7中的一组，EN=0x0f或0xf0。
- W2：Macro0～1、2～3、4～5、6～7中的一组，EN=0x03、0x0c、0x30或0xc0。

reduce_split_mask必须使所选组完整归约；不属于该组的Macro不参与计算。OC可部分屏蔽或全部屏蔽。K尾部不足时由激励/权重补零，不能靠另开一个N组突破Requant限制。

物理lane位置继续采用现有归约树定义。四个算术通道从有效组收集OC0～3，结果散射回原lane位置；输出端口仍为32×8bit数据和32bit valid，但每拍最多4个lane有效，不将高组的结果强行搬到低4lane。

参考实现参数ENABLE_REQUANT默认1，启用上述检查。设置0用于raw-only归约树验证，保留raw行为，INT8 valid保持0。tb_Cluster默认0；Python量化专项覆盖为1。这是编译参数，不是新增运行期pin。

## 参数与固定OC顺序

requant_cfg_t共298bit：conv_mode1 + requant_mode1 + 4×INT32 multiplier + 4×INT10 shift + 4×INT32 zp。107-bit compute descriptor不变。

- requant_multiplier[32*c+:32]：OC c的signed INT32乘数，四项共128bit。
- requant_shift[10*c+:10]：OC c的signed INT10移位，四项共40bit；当前有效配置为−31～31。
- requant_zp[32*c+:32]：OC c的signed INT32有效偏置，四项共128bit。
- requant_mode=0：四个OC共用multiplier/shift的第0项，其余三项不参与算术；zp仍分别使用四项。
- requant_mode=1：四个OC分别使用自己的multiplier/shift，要求conv_mode=1。conv_mode表示普通卷积模式；统一的单组/4OC限制也适用于mode=0。

不需要OC选择字段。组位置由descriptor给出，OC c使用组最左Macro的macro_oc_mask[4*first+c]决定有效性，现有各层merge mask继续影响贡献。参数c始终对应本地OC c，不按有效位数量重新编号。

例如W4选Macro4～7，split=0x01，结果位于物理lane4～7：参数0对应lane4/OC0，参数1对应lane5/OC1；若OC1被屏蔽，lane6仍使用参数2。zp也遵循完全相同的索引。

## 合并后的zero-point

输入offset补偿已由参数生成端合入有效zp。合并后的zp仍是per-weight-output-channel，即使weight使用per-tensor scale，zp也不能因此退化成一个公共值。Cluster只接收这四个zp，没有独立psum_correction字段、加法或缓存。

数值公式为q[n]=clip_INT8(round(raw[n]×multiplier[c]×2^shift[c])+zp[c])；per-tensor时multiplier/shift均选择第0项。multiplier没有隐含Q31除法。最近整数舍入，半整数远离零；zp在round后、最终clip前加入，只在最后饱和到−128～127。

参数生成示例：zp[n]=output_zp_reference[n]+round((-ACT_zp×sum(Wq[:,n]))×effective_scale[n])。Python分别保存raw整数接口golden、中心化数学参考和实数参考，并记录融合zp时的舍入差异；RTL须与接口golden逐元素完全一致。

## 锁存和AS Context

默认REQUANT_CONTEXT_DEPTH=1：batch首Command锁存配置，同一WS批次中跨ACT行复用。AS各Context参数不同时，须将该深度设为至少as_cnt；首K Tile各Context命令加载对应的四项zp和四组scale，后续K Tile必须重复同一参数。公共mode在batch内保持不变。

OS2/AS4配置depth=4：zp表16×32=512bit，scale表16×(32+10)=672bit，合计1184bit，不含valid及batch控制。每拍根据当前最终raw的Context选择四组；per-tensor仅使用batch的第0组scale，zp仍按Context选择。不存在每拍16项zp的需求。

最后raw后的下一沿可同时捕获旧INT8和接受新batch配置，旧结果使用沿前旧参数。输出valid、保持和复位规则不变。配置未知、shift越界、分组违规、Context容量不足或跨Tile参数不一致时，仿真必须命中准确诊断。

## 测试与运行

- tb_ClusterRequant.sv：9611个原始整数向量，以及512个独立四通道Python向量；覆盖两种scale模式、不同参数、16种OC mask及高位置输出组。
- +REQUANT_TEST：168个per-tensor集成case；+REQUANT_CHANNEL_TEST：1536个per-channel case，覆盖七精度、所有可选Macro组、16种mask、OS1/2和Single/WS/AS。
- 独立验证量化valid晚1T、数据保持、复位取消和最早批次配置切换。
- 两个GEMM TB均运行per-tensor weight与per-channel weight版本，每版精确检查512个raw和512个INT8；OS2/AS4另查4096次Psum历史。
- 所有case开始打印英文时间戳和描述；负向检查包括非conv的per-channel配置、单组限制、shift、未知值、AS参数深度及跨Tile scale/zp变化。

仿真使用 [VCS case 入口](../vcs-rtl/README.md)，支持独立编译、数据生成、运行及结果检查。