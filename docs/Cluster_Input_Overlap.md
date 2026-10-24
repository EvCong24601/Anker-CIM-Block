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

`cim_os_cnt/cim_ws_cnt/cim_as_cnt` 均为8bit，范围1～255，WS/AS不能同时大于1。AS还需满足地址、参数和元数据容量；默认 AS17/AS64均拒绝。OS>1 WS 的 Context 数也受 Psum 深度限制。

## Psum 使用条件

```systemverilog
need_psum = (cim_os_cnt > 1) || ((cim_as_cnt > 1) && (act_bits > 4));
```

WS/单 Context 用每 OC 唯一 tmp 融合连续 Slice，仅 OS>1 的最后 Slice 提交 Psum。AS 按 Slice 遍历 Context：首 Tile A0 填充历史，后续 Tile A0执行累加，高 Slice执行 bit fusion。AS A8/A16 即使 OS1 也需要各 Context 的 Psum；AS A4 OS1旁路 Psum。

批次只开放实际使用的低地址 Psum 项，其余项整批关钟。数据限于 signed32，范围要求见 [Requant](Cluster_Requant.md)。

## 时钟门控

Macro 启用 ICG，计算、SRAM读写访问、Hold更新使用独立时钟。常规访问期间计算时钟关闭；同步读必须打开 SRAM 访问时钟。valid 清零所需尾沿保留。

归约树 t1～t6 每节点、每 OC 独立门控，共24个转发数据时钟；终点无需转发时关闭。tmp 按 OC、Psum 按深度和 OC门控。raw 数据/Context 和 INT8 数据按对齐后的结果有效事件门控；valid/control继续由主时钟推进，不直接使用当前命令的 OC mask。

Context 深表使用整批时钟。Per-tensor 时仅共享的第0组 multiplier/shift更新，另外三组关闭时钟；四个逐通道 ZP始终保留。参数保持时通过组合路径读取，无需为读取持续写寄存器。

ICG 为低电平锁存功能模型，工艺实现需映射时钟门控单元并完成 STA。

## 验证入口

`input_overlap` 覆盖七精度、符号、OS1/2、Single/WS2/AS2及地址空拍。`context_stress`覆盖 OS1/WS64、OS1/AS16、OS2/WS8、OS2/AS8，共224例。

`requant_buffers`覆盖七精度、两种scale模式、AS16/AS8、OS1/OS2、空OC输出，检查独立参数、固定槽位、门控及收集未结束时已经发射。`requant_a4_address_bypass`将地址表深度设为1，验证A4旁路。容量用例覆盖AS17、AS64、地址/标签/参数深度不足。

运行方法见 [VCS入口](../vcs-rtl/README.md)。根README的42组逐拍表由独立Python调度模型生成，并与仿真trace核对。

计算OC mask关闭对应Macro结果、归约转发、tmp/Psum及raw/INT8数据寄存器时钟；对应组合算术操作数隔离。门控按已对齐事务标签生效。公共ACT入口、SRAM整行访问和完整行Hold为其他有效OC保留工作能力。

## Psum 数值边界

Psum深度限制Context数量，signed32位宽限制每次写入的数值，两者不能互相替代。WS/单Context的tmp融合、AS的逐Context历史及OS累加均需逐次满足signed32范围。当前写入会截断，最终raw检查不覆盖先前回绕；拒绝、饱和、扩位和错误状态策略为TBD，详见[Requant中的Psum限制](Cluster_Requant.md)。调度和raw/INT8延迟不因该待定项而改变。
