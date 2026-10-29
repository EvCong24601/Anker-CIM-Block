# CIM Cluster 输入与计算说明

八个 SingleMacro 组成一个 Cluster。当前包内ACT Plane、AS地址和量化参数接收与内部发射重叠；输入寄存后下一拍即可发射。正式输出为寄存INT8和逐lane valid，raw signed32仅供TB观察。批次配置及组合解码共享，Packet只存8bit变化地址；每OC的acc/bit-fusion复用一个组合加法器；三条归约路径的末Context完成位决定批次结束，逐lane完整性由独立TB检查。

## 源码与运行

- `RTL/macro/rtl/`：SingleMacro、同步读写SRAM、算术和功能ICG。
- `RTL/cluster/rtl/`：共享package、调度/存储、归约树和四通道Requant。
- `RTL/cluster/tb/`：Cluster、归约、量化和七个具体GEMM顶层；include拆分驱动、参考模型、检查器和case。
- `vcs-rtl/`：各顶层的编译列表、Makefile和用例目录；FSDB自动使用case说明后缀。

从 `vcs-rtl/` 执行 `make run CASE=cluster_default` 或 `make regression`。完整配置和用例说明见 [VCS入口](vcs-rtl/README.md)。

## 调度与缓存

所有多Context AS采用Tile → Slice → Context，包括OS1；WS/单Context采用Tile → Context → Slice。AS参数与地址不要求整包收齐，当前Context已收到即可计算。ACT bank为4096bit，后续Plane固定连续输入。

OUTPUT_PSUM_DEPTH默认16，统一控制Psum、权重地址表及Requant Context表深度；兼容参数可由容量专项单独覆盖。默认权重行地址表16×8bit；仅AS A8/A16使用深表，A4使用当前地址寄存器。Requant参数表默认16项，与OUTPUT_BUFFER_DEPTH一致，所有AS精度均使用固定槽位，不回收、不覆盖。所有精度cim_as_cnt≤16。

非AS关闭地址和量化参数深表，使用当前地址及批次参数。Per-tensor每Context仅使用第0组multiplier/shift并广播，另外三组关钟；per-tensor不加载或消费ZP，逐channel修正仅在TB执行；per-channel仍保留四项ZP。参数c固定对应本地OC c，不按mask压缩。

Psum使用条件：`cim_os_cnt>1 || cim_as_cnt>1`。WS/单Context在tmp中融合Slice；所有AS多Context在Psum中保存各Context结果及融合历史；OS>1还累加K Tile。OS1 WS64合法，OS1 AS16合法，AS17/AS64拒绝。三个count均为8bit、1～255，WS/AS不能同时大于1。

## 时钟与结果

SRAM上升沿采样读写。同步读响应带sram_rd_valid，Macro编号随请求锁存；下一请求不改变当前响应。Macro在输入接受沿读权重，下一沿寄存计算结果，II=1。控制、SRAM访问及ACT分区时钟独立；权重由SRAM输出保持，行号/valid随访问更新；归约转发按节点/OC门控，tmp/Psum及INT8数据按对齐有效事件门控，valid保留清零尾沿。Context表采用整批门控。工艺ICG/SRAM映射及STA需由集成实现确认。

Requant使用一级组合算术及输出寄存器，INT8 valid比raw晚1T，没有输出反压。per-tensor输出`r=clip_INT8(round(raw × multiplier[0] × 2^shift[0]))`，TB再按channel执行`clip_INT8(r+ZP_n)`；per-channel公式保持`clip_INT8(round(raw × multiplier × 2^shift) + zp)`。半整数远离零，shift范围−512～511。merged ZP逐通道，scale支持per-tensor/per-channel。组编号由批次配置统一解码，四通道共享AS Context选择，各OC保留独立隔离和输出门控。

启用量化时每拍只允许一组、最多四个OC：W8八Macro归约，W4对齐四Macro组，W2对齐两Macro组。raw归约单测可关闭量化。中间tmp/Psum必须符合signed32范围；最终clip不修复历史回绕。

## 文档与测试

- [调度、逐拍时序及容量](docs/Cluster_Input_Overlap.md)
- [常规SRAM接口](docs/Cluster_Weight_SRAM_Interface.md)
- [Requant参数、门控及数值范围](docs/Cluster_Requant.md)
- [全部GEMM用例](docs/Cluster_GEMM.md)：13个正向矩阵、5个AS参数负向，包含OS1/WS1/AS8门控与Command切换检查。
- [TB结构和检查职责](docs/Testbench_Guide.md)

`context_stress`覆盖224个OS1/WS64、OS1/AS16、OS2/WS8、OS2/AS8 case。`requant_buffers`覆盖77个固定Context场景、2912个raw和2912个INT8比对，检查参数接收与发射重叠。A4旁路、AS17/64拒绝、异步复位、mask和门控由独立专项检查。所有case开始打印英文时间戳和描述。

完整验证条件与用例映射见[验证清单](docs/Cluster_Verification.md)。

## 附录 A 标准逐拍表

以下42组为raw调度/算术表，C0为首Command+A0接受沿；标准W2/W4/W8从内部发射到raw的D=3/4/5T。各表中的split/EN用于raw归约测试，不代表全部符合Requant单组限制。合法量化配置的输出比对应raw晚1T。

### A1 单 Context os=1 ws=1 as=1
每 Tile K=128；每 Context 总 K=128。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C4 | tmp捕获: R_slice → tmp；输出 |

Ctx0：末内部发射 C1，raw 完成 C4。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C4 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C5 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |

Ctx0：末内部发射 C2，raw 完成 C5。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp；输出 |

Ctx0：末内部发射 C1，raw 完成 C5。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C6 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |

Ctx0：末内部发射 C2，raw 完成 C6。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C6 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C3 | 8'h20（不变） | 读 A2(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C4 | 8'h20（不变） | 读 A3(T0,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 12) → tmp；输出 |

Ctx0：末内部发射 C4，raw 完成 C8。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C6 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |

Ctx0：末内部发射 C2，raw 完成 C7。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C6 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C3 | 8'h20（不变） | 读 A2(T0,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C4 | 8'h20（不变） | 读 A3(T0,Ctx0) | C9 | tmp捕获前 fusion: tmp + (R_slice << 12) → tmp；输出 |

Ctx0：末内部发射 C4，raw 完成 C9。

### A2 AS os=1 ws=1 as=2
每 Tile K=128；每 Context 总 K=128。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | — |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C4 | 填充: R_slice → P[0]；输出 |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C5 | 填充: R_slice → P[1]；输出 |

Ctx0：末内部发射 C1，raw 完成 C4；Ctx1：末内部发射 C2，raw 完成 C5。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C4 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C5 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C6 | fusion: P[0] + (R_slice << 4) → P[0]；输出 |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C7 | fusion: P[1] + (R_slice << 4) → P[1]；输出 |

Ctx0：末内部发射 C3，raw 完成 C6；Ctx1：末内部发射 C4，raw 完成 C7。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | — |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C5 | 填充: R_slice → P[0]；输出 |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C6 | 填充: R_slice → P[1]；输出 |

Ctx0：末内部发射 C1，raw 完成 C5；Ctx1：末内部发射 C2，raw 完成 C6。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C5 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C6 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C7 | fusion: P[0] + (R_slice << 4) → P[0]；输出 |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C8 | fusion: P[1] + (R_slice << 4) → P[1]；输出 |

Ctx0：末内部发射 C3，raw 完成 C7；Ctx1：末内部发射 C4，raw 完成 C8。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C5 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C6 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C7 | fusion: P[0] + (R_slice << 4) → P[0] |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C8 | fusion: P[1] + (R_slice << 4) → P[1] |
| C5 | 8'h20 | 读 A2(T0)，Ctx0复用 | C9 | fusion: P[0] + (R_slice << 8) → P[0] |
| C6 | 8'h21 | 读 A2(T0)，Ctx1复用 | C10 | fusion: P[1] + (R_slice << 8) → P[1] |
| C7 | 8'h20 | 读 A3(T0)，Ctx0复用 | C11 | fusion: P[0] + (R_slice << 12) → P[0]；输出 |
| C8 | 8'h21 | 读 A3(T0)，Ctx1复用 | C12 | fusion: P[1] + (R_slice << 12) → P[1]；输出 |

Ctx0：末内部发射 C7，raw 完成 C11；Ctx1：末内部发射 C8，raw 完成 C12。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C6 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C7 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C8 | fusion: P[0] + (R_slice << 4) → P[0]；输出 |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C9 | fusion: P[1] + (R_slice << 4) → P[1]；输出 |

Ctx0：末内部发射 C3，raw 完成 C8；Ctx1：末内部发射 C4，raw 完成 C9。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C6 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C7 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C8 | fusion: P[0] + (R_slice << 4) → P[0] |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C9 | fusion: P[1] + (R_slice << 4) → P[1] |
| C5 | 8'h20 | 读 A2(T0)，Ctx0复用 | C10 | fusion: P[0] + (R_slice << 8) → P[0] |
| C6 | 8'h21 | 读 A2(T0)，Ctx1复用 | C11 | fusion: P[1] + (R_slice << 8) → P[1] |
| C7 | 8'h20 | 读 A3(T0)，Ctx0复用 | C12 | fusion: P[0] + (R_slice << 12) → P[0]；输出 |
| C8 | 8'h21 | 读 A3(T0)，Ctx1复用 | C13 | fusion: P[1] + (R_slice << 12) → P[1]；输出 |

Ctx0：末内部发射 C7，raw 完成 C12；Ctx1：末内部发射 C8，raw 完成 C13。

### A3 WS os=1 ws=2 as=1
每 Tile K=128；每 Context 总 K=128。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C2 | Ctx1，wgt_raddr=8'h20 | A0(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C4 | tmp捕获: R_slice → tmp；输出 |
| C3 | 8'h20（不变） | 读 A0(T0,Ctx1) | C6 | tmp捕获: R_slice → tmp；输出 |

Ctx0：末内部发射 C1，raw 完成 C4；Ctx1：末内部发射 C3，raw 完成 C6。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C4 | — | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C4 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C5 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |
| C4 | 8'h20（不变） | 读 A0(T0,Ctx1) | C7 | tmp捕获: R_slice → tmp |
| C5 | 8'h20（不变） | 读 A1(T0,Ctx1) | C8 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |

Ctx0：末内部发射 C2，raw 完成 C5；Ctx1：末内部发射 C5，raw 完成 C8。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C2 | Ctx1，wgt_raddr=8'h20 | A0(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp；输出 |
| C3 | 8'h20（不变） | 读 A0(T0,Ctx1) | C7 | tmp捕获: R_slice → tmp；输出 |

Ctx0：末内部发射 C1，raw 完成 C5；Ctx1：末内部发射 C3，raw 完成 C7。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C4 | — | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C6 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |
| C4 | 8'h20（不变） | 读 A0(T0,Ctx1) | C8 | tmp捕获: R_slice → tmp |
| C5 | 8'h20（不变） | 读 A1(T0,Ctx1) | C9 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |

Ctx0：末内部发射 C2，raw 完成 C6；Ctx1：末内部发射 C5，raw 完成 C9。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |
| C5 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C6 | — | A1(T0) |
| C7 | — | A2(T0) |
| C8 | — | A3(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C6 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C3 | 8'h20（不变） | 读 A2(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C4 | 8'h20（不变） | 读 A3(T0,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 12) → tmp；输出 |
| C6 | 8'h20（不变） | 读 A0(T0,Ctx1) | C10 | tmp捕获: R_slice → tmp |
| C7 | 8'h20（不变） | 读 A1(T0,Ctx1) | C11 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C8 | 8'h20（不变） | 读 A2(T0,Ctx1) | C12 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C9 | 8'h20（不变） | 读 A3(T0,Ctx1) | C13 | tmp捕获前 fusion: tmp + (R_slice << 12) → tmp；输出 |

Ctx0：末内部发射 C4，raw 完成 C8；Ctx1：末内部发射 C9，raw 完成 C13。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C4 | — | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C6 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |
| C4 | 8'h20（不变） | 读 A0(T0,Ctx1) | C9 | tmp捕获: R_slice → tmp |
| C5 | 8'h20（不变） | 读 A1(T0,Ctx1) | C10 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |

Ctx0：末内部发射 C2，raw 完成 C7；Ctx1：末内部发射 C5，raw 完成 C10。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |
| C5 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C6 | — | A1(T0) |
| C7 | — | A2(T0) |
| C8 | — | A3(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C6 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C3 | 8'h20（不变） | 读 A2(T0,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C4 | 8'h20（不变） | 读 A3(T0,Ctx0) | C9 | tmp捕获前 fusion: tmp + (R_slice << 12) → tmp；输出 |
| C6 | 8'h20（不变） | 读 A0(T0,Ctx1) | C11 | tmp捕获: R_slice → tmp |
| C7 | 8'h20（不变） | 读 A1(T0,Ctx1) | C12 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C8 | 8'h20（不变） | 读 A2(T0,Ctx1) | C13 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C9 | 8'h20（不变） | 读 A3(T0,Ctx1) | C14 | tmp捕获前 fusion: tmp + (R_slice << 12) → tmp；输出 |

Ctx0：末内部发射 C4，raw 完成 C9；Ctx1：末内部发射 C9，raw 完成 C14。

### A4 单 Context os=2 ws=1 as=1
每 Tile K=128；每 Context 总 K=256。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C2 | Ctx0，wgt_raddr=8'h30 | A0(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C4 | tmp捕获: R_slice；下一拍 tmp 填充 Psum → tmp；P[0] |
| C3 | 8'h30 | 读 A0(T1,Ctx0) | C6 | tmp捕获: R_slice；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |

Ctx0：末内部发射 C3，raw 完成 C6。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C4 | — | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C4 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C5 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C4 | 8'h30 | 读 A0(T1,Ctx0) | C7 | tmp捕获: R_slice → tmp |
| C5 | 8'h30（不变） | 读 A1(T1,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |

Ctx0：末内部发射 C5，raw 完成 C8。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C2 | Ctx0，wgt_raddr=8'h30 | A0(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice；下一拍 tmp 填充 Psum → tmp；P[0] |
| C3 | 8'h30 | 读 A0(T1,Ctx0) | C7 | tmp捕获: R_slice；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |

Ctx0：末内部发射 C3，raw 完成 C7。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C4 | — | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C6 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C4 | 8'h30 | 读 A0(T1,Ctx0) | C8 | tmp捕获: R_slice → tmp |
| C5 | 8'h30（不变） | 读 A1(T1,Ctx0) | C9 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |

Ctx0：末内部发射 C5，raw 完成 C9。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |
| C5 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C6 | — | A1(T1) |
| C7 | — | A2(T1) |
| C8 | — | A3(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C6 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C3 | 8'h20（不变） | 读 A2(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C4 | 8'h20（不变） | 读 A3(T0,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C6 | 8'h30 | 读 A0(T1,Ctx0) | C10 | tmp捕获: R_slice → tmp |
| C7 | 8'h30（不变） | 读 A1(T1,Ctx0) | C11 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C8 | 8'h30（不变） | 读 A2(T1,Ctx0) | C12 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C9 | 8'h30（不变） | 读 A3(T1,Ctx0) | C13 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |

Ctx0：末内部发射 C9，raw 完成 C13。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C4 | — | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C6 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C4 | 8'h30 | 读 A0(T1,Ctx0) | C9 | tmp捕获: R_slice → tmp |
| C5 | 8'h30（不变） | 读 A1(T1,Ctx0) | C10 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |

Ctx0：末内部发射 C5，raw 完成 C10。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |
| C5 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C6 | — | A1(T1) |
| C7 | — | A2(T1) |
| C8 | — | A3(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C6 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C3 | 8'h20（不变） | 读 A2(T0,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C4 | 8'h20（不变） | 读 A3(T0,Ctx0) | C9 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C6 | 8'h30 | 读 A0(T1,Ctx0) | C11 | tmp捕获: R_slice → tmp |
| C7 | 8'h30（不变） | 读 A1(T1,Ctx0) | C12 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C8 | 8'h30（不变） | 读 A2(T1,Ctx0) | C13 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C9 | 8'h30（不变） | 读 A3(T1,Ctx0) | C14 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |

Ctx0：末内部发射 C9，raw 完成 C14。

### A5 WS os=2 ws=2 as=1
每 Tile K=128；每 Context 总 K=256。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C2 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C4 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C6 | Ctx1，wgt_raddr=8'h30 | A0(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C4 | tmp捕获: R_slice；下一拍 tmp 填充 Psum → tmp；P[0] |
| C3 | 8'h20（不变） | 读 A0(T0,Ctx1) | C6 | tmp捕获: R_slice；下一拍 tmp 填充 Psum → tmp；P[1] |
| C5 | 8'h30 | 读 A0(T1,Ctx0) | C8 | tmp捕获: R_slice；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |
| C7 | 8'h30（不变） | 读 A0(T1,Ctx1) | C10 | tmp捕获: R_slice；下一拍 acc: P[1] + tmp → tmp；P[1]；输出 |

Ctx0：末内部发射 C5，raw 完成 C8；Ctx1：末内部发射 C7，raw 完成 C10。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C4 | — | A1(T0) |
| C6 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C7 | — | A1(T1) |
| C9 | Ctx1，wgt_raddr=8'h30 | A0(T1) |
| C10 | — | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C4 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C5 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C4 | 8'h20（不变） | 读 A0(T0,Ctx1) | C7 | tmp捕获: R_slice → tmp |
| C5 | 8'h20（不变） | 读 A1(T0,Ctx1) | C8 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[1] |
| C7 | 8'h30 | 读 A0(T1,Ctx0) | C10 | tmp捕获: R_slice → tmp |
| C8 | 8'h30（不变） | 读 A1(T1,Ctx0) | C11 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |
| C10 | 8'h30（不变） | 读 A0(T1,Ctx1) | C13 | tmp捕获: R_slice → tmp |
| C11 | 8'h30（不变） | 读 A1(T1,Ctx1) | C14 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[1] + tmp → tmp；P[1]；输出 |

Ctx0：末内部发射 C8，raw 完成 C11；Ctx1：末内部发射 C11，raw 完成 C14。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C2 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C4 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C6 | Ctx1，wgt_raddr=8'h30 | A0(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice；下一拍 tmp 填充 Psum → tmp；P[0] |
| C3 | 8'h20（不变） | 读 A0(T0,Ctx1) | C7 | tmp捕获: R_slice；下一拍 tmp 填充 Psum → tmp；P[1] |
| C5 | 8'h30 | 读 A0(T1,Ctx0) | C9 | tmp捕获: R_slice；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |
| C7 | 8'h30（不变） | 读 A0(T1,Ctx1) | C11 | tmp捕获: R_slice；下一拍 acc: P[1] + tmp → tmp；P[1]；输出 |

Ctx0：末内部发射 C5，raw 完成 C9；Ctx1：末内部发射 C7，raw 完成 C11。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C4 | — | A1(T0) |
| C6 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C7 | — | A1(T1) |
| C9 | Ctx1，wgt_raddr=8'h30 | A0(T1) |
| C10 | — | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C6 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C4 | 8'h20（不变） | 读 A0(T0,Ctx1) | C8 | tmp捕获: R_slice → tmp |
| C5 | 8'h20（不变） | 读 A1(T0,Ctx1) | C9 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[1] |
| C7 | 8'h30 | 读 A0(T1,Ctx0) | C11 | tmp捕获: R_slice → tmp |
| C8 | 8'h30（不变） | 读 A1(T1,Ctx0) | C12 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |
| C10 | 8'h30（不变） | 读 A0(T1,Ctx1) | C14 | tmp捕获: R_slice → tmp |
| C11 | 8'h30（不变） | 读 A1(T1,Ctx1) | C15 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[1] + tmp → tmp；P[1]；输出 |

Ctx0：末内部发射 C8，raw 完成 C12；Ctx1：末内部发射 C11，raw 完成 C15。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |
| C5 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C6 | — | A1(T0) |
| C7 | — | A2(T0) |
| C8 | — | A3(T0) |
| C10 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C11 | — | A1(T1) |
| C12 | — | A2(T1) |
| C13 | — | A3(T1) |
| C15 | Ctx1，wgt_raddr=8'h30 | A0(T1) |
| C16 | — | A1(T1) |
| C17 | — | A2(T1) |
| C18 | — | A3(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C6 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C3 | 8'h20（不变） | 读 A2(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C4 | 8'h20（不变） | 读 A3(T0,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C6 | 8'h20（不变） | 读 A0(T0,Ctx1) | C10 | tmp捕获: R_slice → tmp |
| C7 | 8'h20（不变） | 读 A1(T0,Ctx1) | C11 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C8 | 8'h20（不变） | 读 A2(T0,Ctx1) | C12 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C9 | 8'h20（不变） | 读 A3(T0,Ctx1) | C13 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 tmp 填充 Psum → tmp；P[1] |
| C11 | 8'h30 | 读 A0(T1,Ctx0) | C15 | tmp捕获: R_slice → tmp |
| C12 | 8'h30（不变） | 读 A1(T1,Ctx0) | C16 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C13 | 8'h30（不变） | 读 A2(T1,Ctx0) | C17 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C14 | 8'h30（不变） | 读 A3(T1,Ctx0) | C18 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |
| C16 | 8'h30（不变） | 读 A0(T1,Ctx1) | C20 | tmp捕获: R_slice → tmp |
| C17 | 8'h30（不变） | 读 A1(T1,Ctx1) | C21 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C18 | 8'h30（不变） | 读 A2(T1,Ctx1) | C22 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C19 | 8'h30（不变） | 读 A3(T1,Ctx1) | C23 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 acc: P[1] + tmp → tmp；P[1]；输出 |

Ctx0：末内部发射 C14，raw 完成 C18；Ctx1：末内部发射 C19，raw 完成 C23。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C4 | — | A1(T0) |
| C6 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C7 | — | A1(T1) |
| C9 | Ctx1，wgt_raddr=8'h30 | A0(T1) |
| C10 | — | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C6 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C4 | 8'h20（不变） | 读 A0(T0,Ctx1) | C9 | tmp捕获: R_slice → tmp |
| C5 | 8'h20（不变） | 读 A1(T0,Ctx1) | C10 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[1] |
| C7 | 8'h30 | 读 A0(T1,Ctx0) | C12 | tmp捕获: R_slice → tmp |
| C8 | 8'h30（不变） | 读 A1(T1,Ctx0) | C13 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |
| C10 | 8'h30（不变） | 读 A0(T1,Ctx1) | C15 | tmp捕获: R_slice → tmp |
| C11 | 8'h30（不变） | 读 A1(T1,Ctx1) | C16 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[1] + tmp → tmp；P[1]；输出 |

Ctx0：末内部发射 C8，raw 完成 C13；Ctx1：末内部发射 C11，raw 完成 C16。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |
| C5 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C6 | — | A1(T0) |
| C7 | — | A2(T0) |
| C8 | — | A3(T0) |
| C10 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C11 | — | A1(T1) |
| C12 | — | A2(T1) |
| C13 | — | A3(T1) |
| C15 | Ctx1，wgt_raddr=8'h30 | A0(T1) |
| C16 | — | A1(T1) |
| C17 | — | A2(T1) |
| C18 | — | A3(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C6 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C3 | 8'h20（不变） | 读 A2(T0,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C4 | 8'h20（不变） | 读 A3(T0,Ctx0) | C9 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C6 | 8'h20（不变） | 读 A0(T0,Ctx1) | C11 | tmp捕获: R_slice → tmp |
| C7 | 8'h20（不变） | 读 A1(T0,Ctx1) | C12 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C8 | 8'h20（不变） | 读 A2(T0,Ctx1) | C13 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C9 | 8'h20（不变） | 读 A3(T0,Ctx1) | C14 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 tmp 填充 Psum → tmp；P[1] |
| C11 | 8'h30 | 读 A0(T1,Ctx0) | C16 | tmp捕获: R_slice → tmp |
| C12 | 8'h30（不变） | 读 A1(T1,Ctx0) | C17 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C13 | 8'h30（不变） | 读 A2(T1,Ctx0) | C18 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C14 | 8'h30（不变） | 读 A3(T1,Ctx0) | C19 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |
| C16 | 8'h30（不变） | 读 A0(T1,Ctx1) | C21 | tmp捕获: R_slice → tmp |
| C17 | 8'h30（不变） | 读 A1(T1,Ctx1) | C22 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C18 | 8'h30（不变） | 读 A2(T1,Ctx1) | C23 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C19 | 8'h30（不变） | 读 A3(T1,Ctx1) | C24 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 acc: P[1] + tmp → tmp；P[1]；输出 |

Ctx0：末内部发射 C14，raw 完成 C19；Ctx1：末内部发射 C19，raw 完成 C24。

### A6 AS os=2 ws=1 as=2
每 Tile K=128；每 Context 总 K=256。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | — |
| C3 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C4 | Ctx1，wgt_raddr=8'h31 | — |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C4 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C5 | 填充: R_slice → P[1] |
| C4 | 8'h30 | 读 A0(T1)，Ctx0复用 | C7 | acc: P[0] + R_slice → P[0]；输出 |
| C5 | 8'h31 | 读 A0(T1)，Ctx1复用 | C8 | acc: P[1] + R_slice → P[1]；输出 |

Ctx0：末内部发射 C4，raw 完成 C7；Ctx1：末内部发射 C5，raw 完成 C8。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |
| C5 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C6 | Ctx1，wgt_raddr=8'h31 | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C4 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C5 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C6 | fusion: P[0] + (R_slice << 4) → P[0] |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C7 | fusion: P[1] + (R_slice << 4) → P[1] |
| C6 | 8'h30 | 读 A0(T1)，Ctx0复用 | C9 | acc: P[0] + R_slice → P[0] |
| C7 | 8'h31 | 读 A0(T1)，Ctx1复用 | C10 | acc: P[1] + R_slice → P[1] |
| C8 | 8'h30 | 读 A1(T1)，Ctx0复用 | C11 | fusion: P[0] + (R_slice << 4) → P[0]；输出 |
| C9 | 8'h31 | 读 A1(T1)，Ctx1复用 | C12 | fusion: P[1] + (R_slice << 4) → P[1]；输出 |

Ctx0：末内部发射 C8，raw 完成 C11；Ctx1：末内部发射 C9，raw 完成 C12。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | — |
| C3 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C4 | Ctx1，wgt_raddr=8'h31 | — |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C5 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C6 | 填充: R_slice → P[1] |
| C4 | 8'h30 | 读 A0(T1)，Ctx0复用 | C8 | acc: P[0] + R_slice → P[0]；输出 |
| C5 | 8'h31 | 读 A0(T1)，Ctx1复用 | C9 | acc: P[1] + R_slice → P[1]；输出 |

Ctx0：末内部发射 C4，raw 完成 C8；Ctx1：末内部发射 C5，raw 完成 C9。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |
| C5 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C6 | Ctx1，wgt_raddr=8'h31 | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C5 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C6 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C7 | fusion: P[0] + (R_slice << 4) → P[0] |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C8 | fusion: P[1] + (R_slice << 4) → P[1] |
| C6 | 8'h30 | 读 A0(T1)，Ctx0复用 | C10 | acc: P[0] + R_slice → P[0] |
| C7 | 8'h31 | 读 A0(T1)，Ctx1复用 | C11 | acc: P[1] + R_slice → P[1] |
| C8 | 8'h30 | 读 A1(T1)，Ctx0复用 | C12 | fusion: P[0] + (R_slice << 4) → P[0]；输出 |
| C9 | 8'h31 | 读 A1(T1)，Ctx1复用 | C13 | fusion: P[1] + (R_slice << 4) → P[1]；输出 |

Ctx0：末内部发射 C8，raw 完成 C12；Ctx1：末内部发射 C9，raw 完成 C13。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |
| C9 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C10 | Ctx1，wgt_raddr=8'h31 | A1(T1) |
| C11 | — | A2(T1) |
| C12 | — | A3(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C5 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C6 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C7 | fusion: P[0] + (R_slice << 4) → P[0] |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C8 | fusion: P[1] + (R_slice << 4) → P[1] |
| C5 | 8'h20 | 读 A2(T0)，Ctx0复用 | C9 | fusion: P[0] + (R_slice << 8) → P[0] |
| C6 | 8'h21 | 读 A2(T0)，Ctx1复用 | C10 | fusion: P[1] + (R_slice << 8) → P[1] |
| C7 | 8'h20 | 读 A3(T0)，Ctx0复用 | C11 | fusion: P[0] + (R_slice << 12) → P[0] |
| C8 | 8'h21 | 读 A3(T0)，Ctx1复用 | C12 | fusion: P[1] + (R_slice << 12) → P[1] |
| C10 | 8'h30 | 读 A0(T1)，Ctx0复用 | C14 | acc: P[0] + R_slice → P[0] |
| C11 | 8'h31 | 读 A0(T1)，Ctx1复用 | C15 | acc: P[1] + R_slice → P[1] |
| C12 | 8'h30 | 读 A1(T1)，Ctx0复用 | C16 | fusion: P[0] + (R_slice << 4) → P[0] |
| C13 | 8'h31 | 读 A1(T1)，Ctx1复用 | C17 | fusion: P[1] + (R_slice << 4) → P[1] |
| C14 | 8'h30 | 读 A2(T1)，Ctx0复用 | C18 | fusion: P[0] + (R_slice << 8) → P[0] |
| C15 | 8'h31 | 读 A2(T1)，Ctx1复用 | C19 | fusion: P[1] + (R_slice << 8) → P[1] |
| C16 | 8'h30 | 读 A3(T1)，Ctx0复用 | C20 | fusion: P[0] + (R_slice << 12) → P[0]；输出 |
| C17 | 8'h31 | 读 A3(T1)，Ctx1复用 | C21 | fusion: P[1] + (R_slice << 12) → P[1]；输出 |

Ctx0：末内部发射 C16，raw 完成 C20；Ctx1：末内部发射 C17，raw 完成 C21。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |
| C5 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C6 | Ctx1，wgt_raddr=8'h31 | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C6 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C7 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C8 | fusion: P[0] + (R_slice << 4) → P[0] |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C9 | fusion: P[1] + (R_slice << 4) → P[1] |
| C6 | 8'h30 | 读 A0(T1)，Ctx0复用 | C11 | acc: P[0] + R_slice → P[0] |
| C7 | 8'h31 | 读 A0(T1)，Ctx1复用 | C12 | acc: P[1] + R_slice → P[1] |
| C8 | 8'h30 | 读 A1(T1)，Ctx0复用 | C13 | fusion: P[0] + (R_slice << 4) → P[0]；输出 |
| C9 | 8'h31 | 读 A1(T1)，Ctx1复用 | C14 | fusion: P[1] + (R_slice << 4) → P[1]；输出 |

Ctx0：末内部发射 C8，raw 完成 C13；Ctx1：末内部发射 C9，raw 完成 C14。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |
| C9 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C10 | Ctx1，wgt_raddr=8'h31 | A1(T1) |
| C11 | — | A2(T1) |
| C12 | — | A3(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C6 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C7 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C8 | fusion: P[0] + (R_slice << 4) → P[0] |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C9 | fusion: P[1] + (R_slice << 4) → P[1] |
| C5 | 8'h20 | 读 A2(T0)，Ctx0复用 | C10 | fusion: P[0] + (R_slice << 8) → P[0] |
| C6 | 8'h21 | 读 A2(T0)，Ctx1复用 | C11 | fusion: P[1] + (R_slice << 8) → P[1] |
| C7 | 8'h20 | 读 A3(T0)，Ctx0复用 | C12 | fusion: P[0] + (R_slice << 12) → P[0] |
| C8 | 8'h21 | 读 A3(T0)，Ctx1复用 | C13 | fusion: P[1] + (R_slice << 12) → P[1] |
| C10 | 8'h30 | 读 A0(T1)，Ctx0复用 | C15 | acc: P[0] + R_slice → P[0] |
| C11 | 8'h31 | 读 A0(T1)，Ctx1复用 | C16 | acc: P[1] + R_slice → P[1] |
| C12 | 8'h30 | 读 A1(T1)，Ctx0复用 | C17 | fusion: P[0] + (R_slice << 4) → P[0] |
| C13 | 8'h31 | 读 A1(T1)，Ctx1复用 | C18 | fusion: P[1] + (R_slice << 4) → P[1] |
| C14 | 8'h30 | 读 A2(T1)，Ctx0复用 | C19 | fusion: P[0] + (R_slice << 8) → P[0] |
| C15 | 8'h31 | 读 A2(T1)，Ctx1复用 | C20 | fusion: P[1] + (R_slice << 8) → P[1] |
| C16 | 8'h30 | 读 A3(T1)，Ctx0复用 | C21 | fusion: P[0] + (R_slice << 12) → P[0]；输出 |
| C17 | 8'h31 | 读 A3(T1)，Ctx1复用 | C22 | fusion: P[1] + (R_slice << 12) → P[1]；输出 |

Ctx0：末内部发射 C16，raw 完成 C21；Ctx1：末内部发射 C17，raw 完成 C22。

## 附录 B 规范 split 编码

以下按 bit6..bit0 给出26种规范编码，K 限制还需结合 precision、EN 和 OC：

`0000000`、`0000001`、`0000011`、`0000101`、`0000111`、`0001011`、`0001111`、`0010011`、`0010111`、`0011011`、`0011111`、`0100101`、`0100111`、`0101111`、`0110111`、`0111111`、`1000101`、`1000111`、`1001111`、`1010111`、`1011111`、`1100101`、`1100111`、`1101111`、`1110111`、`1111111`

Requant的ZP参数均为生成端已round的signed INT32输出域补偿。per-tensor在CIM饱和INT8输出后仅由TB按channel扩位加ZP并再次clip，不再round；per-channel在RTL内先round、加ZP、再clip，TB不重复补偿。完整公式和参考代码转换见[Requant说明](docs/Cluster_Requant.md)及[Block Spec第6.2节](docs/CIM_Block_Spec.docx)。
