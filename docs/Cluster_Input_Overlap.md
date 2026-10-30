# Cluster 调度、输入时序与容量

当前包内的 ACT Plane、Context 权重地址和 Requant 参数接收与计算发射重叠。首命令在 `cmd_valid_i && cmd_ready_o` 的上升沿接受；已有输入寄存后，下一沿即可发射，不等待整包或全部 Context 参数收齐。

## 输入和发射

WS/单 Context 每个 Context 一包；AS 每个 K Tile 一包，Context 共用完整 ACT。包首接收 A0，随后 P−1 个 Plane 连续输入，P=A位宽/4，没有独立 ACT 握手。AS 后续命令按 Context 顺序接收地址和参数，不重装 A0，允许命令空拍。

发射要求当前包有效、当前 Slice 已加载、当前 Context 命令已接受且批次未完成输入。Requant 参数随同该 Context 命令加载并校验。Context0 可以在 Context1 参数接收的同一沿发射。遇到缺失地址时，保持 Slice/Context/Tile 并等待；后续 ACT 仍按协议接收。

所有多 Context AS，包括 OS1，采用 Tile → Slice → Context；WS/单 Context 采用 Tile → Context → Slice。下一包在当前包末次发射之后的下一沿接受；一个 ACT bank 不支持下一包覆盖当前未消费输入。

## 无空拍周期公式

令 R=max(cim_ws_cnt,cim_as_cnt)，t/c/p 分别为 Tile/Context/Slice，C0 为首命令接受沿。

- WS/单 Context：包起点 `S=(t*R+c)*(P+1)`，Slice p 在 `S+p` 接收，在 `S+1+p` 发射。
- AS：包起点 `S=t*(1+R*P)`，Context c 命令在 `S+c` 接收，Slice p 在 `S+p` 接收，在 `S+1+p*R+c` 发射。
- 地址有空拍时，按原顺序等待当前 Slice 和 Context 就绪，发射最早为对应接收沿后一拍。
- Macro 在发射沿同步读 SRAM 并寄存 ACT，下一沿寄存局部计算结果，II=1。标准 W2/W4/W8 归约路径从末次发射到 raw 分别为 3/4/5T；Requant 比对应 raw 晚 1T。

A16、AS2 的 OS1/OS>1 都采用以下包内时序：

- C0：接收 Ctx0 地址、参数和 A0。
- C1：接收 Ctx1 地址、参数和 A1；发射 A0/Ctx0。
- C2：接收 A2；发射 A0/Ctx1。
- C3：接收 A3；发射 A1/Ctx0。
- C4～C8：发射 A1/Ctx1、A2/Ctx0、A2/Ctx1、A3/Ctx0、A3/Ctx1。
- C9：可接收下一 Tile 包。若为最后 Tile，批次仍须等待结果发布。

## 固定 Context 存储

- `OUTPUT_BUFFER_DEPTH=16`：每 OC 的 signed32 Psum 深度，同时限制所有精度的 `cim_as_cnt≤16`。
- `REQUANT_CONTEXT_DEPTH=OUTPUT_BUFFER_DEPTH`：默认16个固定参数表项，Context i 使用表项 i；不回收槽位，没有 FIFO 指针。容量覆盖 A4/A8/A16。测试可覆盖为更小值验证拒绝。
- `WGT_RADDR_BUFFER_DEPTH=16`：16×8bit 行地址表，共128bit；AS A8/A16 每 Tile 收集并跨 Slice 复用。A4 AS 旁路深表，仅使用当前地址寄存器。
- `MAX_CONTEXTS=64`：标签和完成状态容量，允许 OS1 WS64；独立于 Psum 物理深度。

非 AS 关闭两个 Context 深表：权重地址使用当前 Command，Requant 使用批次配置寄存器。AS 参数首 K Tile 加载，后续 Tile 校验有效参数一致；消费结果不释放或覆盖参数槽位。

`cim_os_cnt/cim_ws_cnt/cim_as_cnt` 均为9bit，范围1～511，WS/AS不能同时大于1。AS还需满足地址、参数和元数据容量；默认 AS17/AS64均拒绝。OS>1 WS 的 Context 数也受 Psum 深度限制。

## Psum 使用条件

```systemverilog
need_psum = (cim_os_cnt > 1) || ((cim_as_cnt > 1) && (act_bits > 4));
```

WS/单 Context 用每 OC 唯一 tmp 融合连续 Slice，仅 OS>1 的最后 Slice 提交 Psum。AS 按 Slice 遍历 Context：首 Tile A0 填充历史，后续 Tile A0执行累加，高 Slice执行 bit fusion。所有 AS 多 Context 批次（包括 OS1/A4）均在 Psum 中保存各 Context 的结果及融合历史。

批次只开放实际使用的低地址 Psum 项，其余项整批关钟。数据限于 signed32，范围要求见 [Requant](Cluster_Requant.md)。

## 时钟门控

Macro 启用 ICG，控制、SRAM读写和ACT分区使用独立时钟；权重由SRAM输出保持，行号/valid随访问更新。常规访问期间计算时钟关闭；同步读必须打开 SRAM 访问时钟。valid 清零所需尾沿保留。

归约树 t1～t6 每节点、每 OC 独立门控，共24个转发数据时钟；终点无需转发时关闭。tmp 按 OC、Psum 按深度和 OC门控。raw 数据/Context 和 INT8 数据按对齐后的结果有效事件门控；valid/control继续由主时钟推进，不直接使用当前命令的 OC mask。

Context 深表使用整批时钟。Per-tensor 时仅共享的第0组 multiplier/shift更新，另外三组关闭时钟；per-tensor不更新或读取四项ZP，修正在TB执行；per-channel仍保存四项逐通道ZP。参数保持时通过组合路径读取，无需为读取持续写寄存器。

ICG 为低电平锁存功能模型，工艺实现需映射时钟门控单元并完成 STA。

## 验证入口

`input_overlap` 覆盖七精度、符号、OS1/2、Single/WS2/AS2及地址空拍。`context_stress`覆盖 OS1/WS64、OS1/AS16、OS2/WS8、OS2/AS8，共224例。

`requant_buffers`覆盖七精度、两种scale模式、AS16/AS8、OS1/OS2、空OC输出，检查独立参数、固定槽位、门控及收集未结束时已经发射。`requant_a4_address_bypass`将地址表深度设为1，验证A4旁路。容量用例覆盖AS17、AS64、地址/标签/参数深度不足。

运行方法见 [VCS入口](../vcs-rtl/README.md)。[标准逐拍文档](Cluster_Timing_Tables.md)中的42组逐拍表由独立Python调度模型生成，并与仿真trace核对。

计算OC mask关闭对应Macro结果、归约转发、tmp/Psum及tmp/Psum和INT8数据寄存器时钟；对应组合算术操作数隔离。门控按已对齐事务标签生效。公共ACT入口、SRAM整行访问和完整行Hold为其他有效OC保留工作能力。

## Psum 数值边界

Psum深度限制Context数量，signed32位宽限制每次写入的数值，两者不能互相替代。WS/单Context的tmp融合、AS的逐Context历史及OS累加均需逐次满足signed32范围。当前写入会截断，最终raw检查不覆盖先前回绕；拒绝、饱和、扩位和错误状态策略为TBD，详见[Requant中的Psum限制](Cluster_Requant.md)。调度和raw/INT8延迟不因该待定项而改变。

## 共享事务标签与结果存储

批次描述符由整个 Cluster 共享。四级流水仅携带 valid、Slice、Context 和 K Tile；tmp 标签按 2/4/8 Macro 三种归约延迟路径共享，lane 通过批次的归约配置选择路径。默认 Context 宽6bit，每个窄标签18bit；四级流水72bit、三路径 tmp 标签54bit，逐lane tmp valid另32bit。三路径 raw Context 指针共18bit。逐lane兼容视图为组合连线，不复制配置寄存器。

Psum 使用条件为 `cim_os_cnt>1 || cim_as_cnt>1`。OS1/AS2～16（含 A4）按 Context 保存结果；深度16允许AS16，AS17/AS64拒绝。AS的 Tile→Slice→Context 发射顺序以及包内接收/发射重叠保持。A4仅旁路深权重地址表，Requant Context 参数仍须保留至消费。

raw 数据直接选择对应 Context 的 Psum 或单 Context/WS 的 tmp，不另设1024bit raw DFF。raw valid 保持原发布时刻，INT8 输出寄存器及 valid 仍晚1T。无效周期 raw 视图可能变化；正式 INT8 输出在无 valid 时保持。各路径指针和标签按提前门控请求更新。

## 统一 Buffer 深度

集成使用 `OUTPUT_PSUM_DEPTH`（默认16）统一设置 Psum、权重CIM读地址表及Requant Context参数表深度。兼容参数依赖为 `OUTPUT_BUFFER_DEPTH=OUTPUT_PSUM_DEPTH`，`WGT_RADDR_BUFFER_DEPTH=OUTPUT_BUFFER_DEPTH`，`REQUANT_CONTEXT_DEPTH=OUTPUT_BUFFER_DEPTH`；仅覆盖统一参数即可联动三表。容量负向测试可以显式覆盖兼容参数，显式覆盖会优先于默认联动。MAX_CONTEXTS为独立的调度标签容量，仍须满足其限制。

每个物理输出OC由acc和bit-fusion共用一个组合加法器，全部Context通过Psum索引复用；不同OC之间保持独立，以支持并行输出。Context深度只扩展状态存储，不复制算术单元。

## 组合逻辑共享

每个物理OC的fusion和acc操作互斥，共享一个64bit有符号加法表达式。WS的fusion在tmp捕获路径，AS的fusion及OS累加在tmp消费路径；选择相应操作数后求和，再送回原有tmp/Psum写回路径。算术扩展、移位、存储截断、raw发布及INT8晚1T规则保持。闲置操作数隔离为0，各OC保持独立；TB检查两个操作不会同时请求同一个加法器。

批次仅进行一份组合解码，生成Macro有效需求、物理归约组、结构组大小、延迟路径、输出lane mask、ACT digit数量及末Slice/Tile条件。标签视图、发射、ACT选择和提前门控请求复用该解码。结构组大小包含被禁用的Macro，不能用实际使能数量决定路径延迟。输入Command首次接受的合法性检查仍读取输入配置。

归约树分别对early/c0/c1/c2控制进行对齐解码，得到叶节点、两Macro、四Macro及根节点的OC存活信息。数据左右选择、终点tap和提前一拍的转发门控请求复用对应流水级的结果。不同流水级不共用实时控制；子节点的独立OC门控和数据保持规则保持。

本结构没有增加流水或DFF，计入9bit count及唯一conv_mode后，默认名义DFF按声明差量推导为33496bit，ICG锁存位684。MacroSliceFusion保持现状。共享加法器的输入选择器可能影响关键路径，面积及时序收益须由实际综合及STA评估。

## 零输出批次的标签与门控

内部issue保留原输入接收、计数和批次结束时序；当有效输出lane mask为0时，`pipe_meta[0].valid`保持0，不向归约与tmp路径传播有效事务。空批次的旧valid不会在下一批次更新共享mask后被重新解释。

tmp门控请求在捕获沿必须与真实`capture_valid`一致。`requant_empty_batch`在ready最早恢复时发送下一批次，检查全OC屏蔽批次没有多余输出、误开钟或无消费写入；父节点mask形成零输出的情况由同一有效mask条件处理。非空批次的流水延迟保持原定义。

Per-tensor整个zero-point buffer关钟：AS Context ZP使用`deep_zp_clock`（复用现有`channel_scale_clock`门控域），批次ZP使用`batch_zp_clock`（复用`batch_channel_clock`）。mode=0两者均无时钟脉冲；共享第0项scale仍使用自己的时钟，不受影响。mode=1维持原ZP加载、保持和算术结果；异步复位仍有效。不新增ICG或修改配置容量。TB检查实际ZP时钟电平及存储保持，门控/旁路镜像继续逐拍对照。
