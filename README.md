# CIM Block Cluster 与 SingleMacro 完整规格

版本：整合版 v0.1。日期：2026-10-19。

## 当前 Cluster 参考实现更新 2026-10-19

仓库 RTL 层级已收平为 `RTL/cluster` 和 `RTL/macro`。Cluster 测试目录按 `sv_code`、`py`、`log`、`data` 分类；从仓库根目录运行 `python RTL/cluster/cluster_tb/py/run_regression.py --gate-unit --latency-audit --log regression_tmp_default.log`。VCS 的文件列表与检查路径也已同步。

最新可运行的仿真参考实现位于 [cluster_tb](RTL/cluster/cluster_tb/README.md)。已加入归约终点后的 tmp 寄存级、WS/AS 的 fusion/acc 路由、提前一拍的 ICG 使能和未使用高地址深度的整批门控。六种配置为 `(os,ws,as)=(1,1,1)、(1,1,2)、(1,2,1)、(2,1,1)、(2,2,1)、(2,1,2)`，三个 count 均最小为 1，ws/as 不能同时大于 1。

当前标准 W2/W4/W8 映射的末输入到 raw 完成分别为 **3T/4T/5T**；AS 在首 Tile/A0 填充 Psum、后续 Tile/A0 做 acc、其他 phase 做 fusion；os=1 在 tmp 完成后直接输出。默认 1368 个 Cluster case 和 208 个归约门控 case 已通过。尚未综合/STA，未包含 requant，不增加对外 pin。

以下整合规格保留了早期的 4T 目标、零值 count 和逐拍示例，作为规格来源归档；这些旧口径不代表当前参考 TB 行为。当前流水、参数、六种配置、回归与 CSV 以 [cluster_tb 说明](RTL/cluster/cluster_tb/README.md)及其随附代码为准，未更新的 Requant/正式接口讨论仍属于规格目标。

本文将单 Macro、8 Macro 组成的单 Cluster、Macro 间 K 归约级联、Activation Fusion、跨 K Tile Psum、逐拍输入和输出协议组织为同一份规格。CIM-Block 在本文中等同于一个 Cluster。外部 CV-Core 提供 Command 和 Activation；跨 Cluster 的全局调度不属于本模块。

单 Macro 采用 SingleMacro v0.2 的固定一拍契约：上升沿 n 接受一个 activation digit Phase，n+1 沿后输出四路 signed18 局部和，Phase II=1。Cluster 先归约相同 Phase 的跨 Macro 贡献，再做 A4/A8/A16 Fusion 和 Psum。Cluster 的 4T raw Psum 时序沿用逐拍输入 v2.7 的目标流水，尚不能据此宣称 Cluster RTL 已实现或完成时序签核。

## 目录

1. [来源与整合口径](#1-来源与整合口径)
2. [层级边界与总体参数](#2-层级边界与总体参数)
3. [精度编码与统一数值模型](#3-精度编码与统一数值模型)
4. [Cluster 外部接口与命令](#4-cluster-外部接口与命令)
5. [权重存储与 Activation 数据布局](#5-权重存储与-activation-数据布局)
6. [SingleMacro 接口与内部计算](#6-singlemacro-接口与内部计算)
7. [Macro 间级联与可配置归约树](#7-macro-间级联与可配置归约树)
8. [Command ACT 与数据流调度](#8-command-act-与数据流调度)
9. [Activation Fusion 与跨 Tile Psum](#9-activation-fusion-与跨-tile-psum)
10. [端到端流水与逐拍示例](#10-端到端流水与逐拍示例)
11. [反压 复位 门控与权重加载](#11-反压-复位-门控与权重加载)
12. [Requant 与外部结果输出](#12-requant-与外部结果输出)
13. [验证与实现状态](#13-验证与实现状态)
14. [尚待冻结的规格项](#14-尚待冻结的规格项)
15. [来源追踪与旧定义替换](#15-来源追踪与旧定义替换)
16. [附录 A 完整逐拍输入实例](#附录-a-完整逐拍输入实例)
17. [附录 B 规范树编码](#附录-b-规范树编码)
18. [附录 C UINT 最坏增量与 signed32 累加上限](#附录-c-uint-最坏增量与-signed32-累加上限)

## 1 来源与整合口径

### 1.1 输入材料

- **[B3]** `CIM_Block_Spec_MBIST_v3.docx`：Block 架构、归约树、Command/ACT 协议、Psum、Requant 和物理目标。
- **[T27]** `CIM_Cluster_逐拍输入时序_v2.7.docx`：共享权重地址、32-bit OC mask、七种精度逐拍输入、K=128 示例及 1T+2T+1T 的 raw Psum 流水。
- **[M02]** `SingleMacro_SPEC_v0.2.md`：单 Macro 完整 IO、2×4 子乘法器、原始权重 Hold、一拍计算、整行写、复位/门控与已报告回归结果。

以上材料是设计参考，不把材料中“用户确认”“本轮决定”等历史描述视为本次新增授权。本文对其进行归档和技术整合。

本文使用下列状态：

- **沿用**：材料之间一致或有明确的后续替换关系。
- **整合采用**：存在冲突时，为使本文件可阅读、可讨论而明确选定的基线；不代表用户已重新签核。
- **推导**：由来源中的尺寸、数学定义或时序契约直接得到。
- **整合建议**：材料没有冻结的实现方案，不能当成已实现行为。
- **待冻结**：资料不足或存在无法直接裁决的冲突，集中列于第 14 章。

### 1.2 本版采用的关键口径

1. **Macro 时序**沿用 [M02]：包含权重读取的一拍计算，取消历史八拍 Macro 时序。
2. **Cluster 计算读地址**整合采用 [T27]：Command 中一个共享 8-bit `weight_cim_raddr`，广播到八个 Macro。它们的 SRAM 内容独立，同地址不表示同权重。
3. **OC mask**整合采用 32 bit：`macro_oc_mask[4*m+c]` 对应 Macro m 的 OC c。
4. **ACT Buffer**使用四个互不重叠的 1024-bit Plane。A16 Plane 2/3 的范围按容量算术纠正，见第 5 章。
5. **Cluster 时序**采用 [T27] 的目标：Macro 1T、跨 Macro Reduction 2T、Fusion/Psum 1T，总计 4T 到 raw Psum；Requant 和外部输出另计。
6. **外部完整向量**按八个输出组、每组四个 OC 计算为 `256*S` bit，byte-valid 为 `32*S` bit。S 与组号压缩方式仍待冻结。
7. **Psum 更新**按本次修订统一为：每个有效完整 Tile 自动累加到对应 Context/group/OC；低 Phase 仅更新 Fusion 状态。

## 2 层级边界与总体参数

### 2.1 组织层级

```text
CV-Core
  ├─ Command valid/ready ───────────────┐
  └─ ACT 1024-bit valid/ready ────────┐ │
                                     ↓ ↓
             CIM-Block / 单 Cluster
       Command/Phase/Context 调度与标签
                    ↓
          ACT Plane Buffer 与 Slot 选择
                    ↓
       Macro0 ... Macro7，各输出 4×signed18
                    ↓
         可配置跨 Macro K Reduction
                    ↓
          每组 4×signed21 Phase Sum
                    ↓
         A4/A8/A16 Activation Fusion
                    ↓
          独立 Context 跨 K Tile Psum
                    ↓
             Requant 与输出拼装
                    ↓
          外部 Local Shared Memory
```

“Macro 间级联”在本架构中是局部和的树形 K 归约。Macro 之间没有将一个 Macro 的结果再送入另一个 Macro 作为 ACT 的链式计算接口。权重 digit 的重组在 Macro 内，activation digit 的重组在 Cluster 内。

### 2.2 固定规模

- 每 Macro：4 OC；Weight SRAM 为 256 行 × 1024 bit，即 32 KiB。
- 每 OC 每行：256 bit，即 32 B。四个 OC 并行共享一个本地行地址。
- 每 Cluster：8 Macro、32 个物理 OC 位置、256 KiB Weight SRAM。
- 每 Cluster Group：16 Cluster、128 Macro、4 MiB Weight SRAM。
- [B3] 同时写有“最大激活 8 个 Cluster”，其运行约束与峰值统计口径待明确，不能默认 16 个 Cluster 可同时工作。
- 单 Macro 每 OC：128 个 2×4 子乘法器；每 Macro 512 个；每 Cluster 4096 个。
- [B3] 的每 Cluster 2048 个 4×4 Lane 是旧粒度等效资源描述；当前 RTL 组织以 [M02] 的 2×4 子乘法器为准。
- 单归约输出组：4 个逻辑 OC；最多 8 个独立组，因此最多 32 OC/Cluster。
- 单组有效 K：最大 256；多 Tile 通过 Psum 支持更大总 K。

### 2.3 时钟与吞吐

- 目标频点：64、128、256 MHz；256 MHz 周期为 3.90625 ns。
- Macro Phase Latency=1、Phase II=1；三个频点均是设计目标，未完成物理签核。
- 完整 activation 需 P=`bA/4` 个 Phase：A4=1、A8=2、A16=4。
- 理想连续发射下，完整任务吞吐目标 II 为 A4/A8/A16=1/2/4；AS 可以交叠多个 Context，不能据此要求相邻完整结果固定间隔 P 拍。

按 1 MAC=2 Ops，部分积不重复计数：

```text
P_macro   = K_row × 4 × 2 × Fclk / P
P_cluster = 8 × P_macro
P_group   = N_active_cluster × P_cluster
```

按 16 个 Cluster 全部参与、256 MHz 计算，W8A8/W4A8/W4A4 分别为 4.194304/8.388608/16.777216 TOPS。若实际最多同时激活 8 个 Cluster，相同条件下分别为 2.097152/4.194304/8.388608 TOPS。两组均为资源算术上限，不能代替运行配置确认或实测。

## 3 精度编码与统一数值模型

### 3.1 precision 编码

```text
precision=0  W2A4   bW=2  K_row=128  P=1  phase={0}
precision=1  W2A8   bW=2  K_row=128  P=2  phase={0,1}
precision=2  W4A4   bW=4  K_row=64   P=1  phase={0}
precision=3  W4A8   bW=4  K_row=64   P=2  phase={0,1}
precision=4  W4A16  bW=4  K_row=64   P=4  phase={0,1,2,3}
precision=5  W8A8   bW=8  K_row=32   P=2  phase={0,1}
precision=6  W8A16  bW=8  K_row=32   P=4  phase={0,1,2,3}
precision=7  保留，非法
```

### 3.2 signed_en 和 digit 的符号

`signed_en=0` 表示 UINT×UINT；`signed_en=1` 表示 INT×INT。INT 的补码分解只将完整整数的最高 digit 解释为 signed，其余 digit 均为 unsigned。

- W2：每个完整权重按 signed2 解释。
- W4：2-bit digit d0 为 unsigned2，d1 为 signed2。
- W8：d0/d1/d2 为 unsigned2，d3 为 signed2。
- A4：p0 为 signed4。
- A8：p0 为 unsigned4，p1 为 signed4。
- A16：p0/p1/p2 为 unsigned4，p3 为 signed4。

UINT 模式下上述所有 digit 都为 unsigned。不采用旧浮点尾数的全 signed nibble 编码。

### 3.3 数学基准

```text
W[c,j]      = Σ_d digitW[c,j,d] × 2^(2d)
A[j]        = Σ_p digitA[j,p]   × 2^(4p)
S_m[c,p]    = Σ_j W_m[c,j] × digitA_m[j,p]
R_g[c,p]    = Σ_(m 属于 group g) S_m[c,p]    // 只计有效贡献
T[ctx,g,c]  = Σ_p R_g[c,p] × 2^(4p)
Psum[ctx,g,c] = Σ_(完整 K Tile t) T[t,ctx,g,c]
```

上述求和的每个阶段使用独立 Context、group、OC 和 Tile 标签；不同输出通道、不同 Context 不能相加。同组 Macro 覆盖的是同一输出的不同 K 段。

## 4 Cluster 外部接口与命令

### 4.1 计算和输出接口

方向均以 Cluster 为视角。

- `clock`，输入 1 bit：上升沿时钟。
- `reset`，输入 1 bit：高有效异步复位；释放由集成端同步。
- `cmd_i`，输入 `CTRL_W` bit：每个计算 Phase 的完整 descriptor。
- `cmd_valid_i/cmd_ready_o`，输入/输出各 1 bit：Command 接收握手。
- `act_data_i[1023:0]`，输入：一个 Plane，含 256 个 4-bit digit。
- `act_valid_i/act_ready_o`，输入/输出各 1 bit：ACT 独立接收握手。
- `requant_odata_o[256*S-1:0]`，输出：S 个深度位置、每个最多 8×4 个 8-bit 结果。
- `requant_lane_valid_o[32*S-1:0]`，输出：每个结果字节的有效位。
- `out_valid_o/out_ready_i`，输出/输入各 1 bit：Requant 后完整向量握手。

`raw_psum_valid` 是 Requant 前的内部就绪观测事件；材料未将其冻结为外部端口。不能把它与 `out_valid_o` 合并命名。

### 4.2 cluster_ctrl_t

沿用字段按以下顺序从 packed struct 的高位到低位排列：

```systemverilog
// 本声明准确表示 T27 当前 TB 的 131-bit 载荷。
// count 位宽尚未冻结。
typedef struct packed {
    logic [15:0] os_cnt;
    logic [15:0] ws_cnt;
    logic [15:0] as_cnt;
    logic [6:0]  reduce_split_mask;
    logic [7:0]  macro_en_mask;
    logic [31:0] macro_oc_mask;
    logic [7:0]  weight_cim_raddr;
    logic [23:0] act_slot_sel;
    logic [2:0]  precision;
    logic        signed_en;
} cluster_ctrl_t_tb;
```

字段语义：

- `os_cnt`：每个输出 Context 要完成的完整 K Tile 数，不是 Phase 数或延迟。
- `ws_cnt`：Weight Reuse Context 数；非零选择 WS。
- `as_cnt`：Activation Reuse Context 数；非零选择 AS。
- `ws_cnt/as_cnt` 互斥；都为零时为 OS，示例取一个活跃 Context。`os_cnt=0` 的编码含义未定义，本文示例仅使用正值。
- `reduce_split_mask[6:0]`：树节点的 split/merge 配置，bit0 为根。
- `macro_en_mask[m]`：Macro m 是否参与当前 Phase。
- `macro_oc_mask[4*m+c]`：Macro m 的 OC c 是否贡献结果。
- `weight_cim_raddr[7:0]`：八个 Macro 共享的本地读行号，不自动递增。
- `act_slot_sel[3*m +: 3]`：Macro m 当前 Plane 的 Slot。
- `precision/signed_en`：见第 3 章。

计数参数化时：`CTRL_W=OS_CNT_W+WS_CNT_W+AS_CNT_W+83`。三个 count 都为 16 bit 时为 131 bit。

### 4.3 采样与配置有效期

```text
cmd_fire       = cmd_valid_i && cmd_ready_o
act_write_fire = act_valid_i && act_ready_o
consume_fire   = Command/ACT/资源匹配后的一次实际计算发射
```

三者是不同事件。每个 Phase 都需要一条独立成功接收的 Command，即使地址和配置相同，或 AS 仅保持已有 ACT。没有独立的 `wgt_raddr` 顶层计算 pin；它是 `cmd_i.weight_cim_raddr` 的简称。

权重地址、Slot、tree/enable/mask 等逐 Command 采样。precision、signed 模式的安全切换及 OS/WS/AS/count 的 Tile 配置必须与在途计算隔离；至少 precision、模式和三个 count 未排空不得切换。同一逻辑 Context 的各 Phase 必须使用一致的逻辑权重和 K/OC 映射。

有队列时，接收和实际发射可以分离，必须分别维护接收指针与执行指针。执行 Phase/复用计数仅随真实 `consume_fire` 推进，不能仅看到 `valid` 就推进。

### 4.4 权重预加载接口

[T27] 的以下接口属于 TB preload，尚不是正式冻结的 Cluster 顶层写接口：

```text
weight_wen_i[7:0]     bit m 选择写 Macro m
weight_waddr_i[7:0]   所有被选 Macro 使用的写行号
weight_wdata_i[8191:0]
    Macro m 的数据 = weight_wdata_i[1024*m +: 1024]
```

每个被选择的 Macro 一次写完整 1024-bit 行；具体写入许可遵循第 6.7 节。不引入 SRAM 同拍读写能力的假设。

## 5 权重存储与 Activation 数据布局

### 5.1 Weight SRAM 行布局

```text
row[256*c + bW*j +: bW] = W[c,j]
c=0..3，j=0..K_row-1

OC0 = row[255:0]
OC1 = row[511:256]
OC2 = row[767:512]
OC3 = row[1023:768]
```

每个 Macro 的 4 OC 使用同一个 8-bit 行地址。32 B/OC/行对应 W2=128、W4=64、W8=32 个权重。地址在各 Macro 中访问不同物理 SRAM，因此共享 Row0x20 可以装载八份不同 K/OC 权重。

`cim_oc_mask` 仅影响计算，不影响整行写。没有写 mask、case/index 元数据或行地址自动递增。物理 bitcell 排列可以不同，但 memory wrapper 须恢复本逻辑 packing。

### 5.2 四 Plane ACT Buffer

逻辑容量为 4096 bit，表示最多 256 个 A16 元素的四个 4-bit Plane：

```text
Plane0 = act_buffer[1023:0]       = ACT[k][3:0]
Plane1 = act_buffer[2047:1024]    = ACT[k][7:4]
Plane2 = act_buffer[3071:2048]    = ACT[k][11:8]
Plane3 = act_buffer[4095:3072]    = ACT[k][15:12]

Plane_p[4*k +: 4] = ACT[k][4*p +: 4]，k=0..255
```

A4 使用 Plane0；A8 使用 Plane0/1；A16 使用 Plane0…3。[B3] Plane2/3 中出现的 2028 下界会造成重叠，不沿用。

四 Plane 是同一逻辑 activation 的 digit 存储，不是四套完整 A16 ping-pong Buffer。Plane 的有效位、Tile/Context 所属及剩余消费者计数必须单独管理。

[B3] 同时写“4096-bit/Cluster”及“Group 共享一组 Buffer”。本文规定单 Cluster 所见的上述逻辑视图；Group 物理是否共用、如何广播、如何汇总 ready 属于待冻结的上层集成，不能重复计算容量或默认已解决跨 Cluster 反压。

### 5.3 Slot 选择与 Macro ACT 输入

```text
K_start(m) = slot[m] × K_row
cim_idata_m[4*j +: 4] = Plane_p[4*(K_start(m)+j) +: 4]
```

- W2：Slot=0…1，每 Slot 128 digit/512 bit；`cim_idata[511:0]` 全有效。
- W4：Slot=0…3，每 Slot 64 digit/256 bit；放入 `[255:0]`，高 256 bit 补零。
- W8：Slot=0…7，每 Slot 32 digit/128 bit；放入 `[127:0]`，高 384 bit 补零。

Slot 在 Cluster 内选择。Macro 不接收 Slot，不保存完整 Plane。一个 Macro 的四个 OC 共用同一 512-bit 输入和同一个 Slot。

K Tail 由上游在无效 digit 位置补零；Macro 不额外设置 K mask。OC Tail 由 OC mask 和输出 lane-valid 屏蔽。未使用高位不能影响数值。

### 5.4 Plane 覆盖规则

Plane 尚有后续消费者时不得覆盖。AS 中每个 Plane 要完成 R=`as_cnt` 次成功发射才能释放。没有 `act_write_fire` 不写 ACT；没有 `consume_fire` 不减少消费者计数。

若同沿消费旧 Plane 并写入同一位置，计算须可靠捕获旧数据且本次确为最后消费者。若要求首条 Command 和 ACT 在 C0 接收并于 C0 发射，还需明确可用的 ACT/Command 旁路；普通同步写 Buffer 在沿后才更新，不能仅凭“同拍握手”推导“同拍读到新值”。无旁路时实际发射延后，4T 从延后的实际发射沿计数。

## 6 SingleMacro 接口与内部计算

### 6.1 模块边界

Macro 只计算一个 activation digit Phase 的四个局部点积。不包含 ACT Plane Buffer、tree mask 解码、跨 Macro 归约、Activation Fusion、Psum、Requant、全局地址生成或 Context 存储。

`os_cnt/ws_cnt/as_cnt`、`context_idx/group_id/K Tile` 不进入 Macro IO。物理 macro_id 来自实例连接，不是输入端口。

### 6.2 RTL 接口声明

```systemverilog
module SingleMacro (
    input  logic          clock,
    input  logic          reset,
    input  logic          cim_ren,
    input  logic [511:0]  cim_idata,
    input  logic [7:0]    cim_raddr,
    input  logic          cim_station,
    input  logic [3:0]    cim_oc_mask,
    input  logic [2:0]    cim_precision,
    input  logic          cim_signed_en,
    input  logic [1:0]    cim_phase,
    input  logic          cim_wen,
    input  logic [7:0]    cim_waddr,
    input  logic [1023:0] cim_wdata,
    output logic [71:0]   cim_odata,
    output logic          cim_odata_valid,
    output logic [3:0]    cim_odata_oc_mask,
    output logic [1:0]    cim_odata_phase
);
```

- `cim_ren`：本沿请求发射一个 Phase；无 ready。
- `cim_idata`：当前 Slot 的 4-bit digit 向量。
- `cim_raddr`：本地读行号；本整合版由 Cluster 共享读地址驱动。
- `cim_station`：1=读 SRAM 并刷新原始行 Hold；0=复用有效同地址 Hold。
- `cim_oc_mask`：四个本地 OC 的有效位。
- `cim_precision/cim_signed_en/cim_phase`：当前事务的精度、符号和 activation digit 编号。
- `cim_wen/cim_waddr/cim_wdata`：整行写请求、行号和全部 1024-bit 数据。
- `cim_odata[18*c +: 18]`：OC c 的 signed18 Phase Sum，OC0 在低位。
- `cim_odata_valid`：当前周期输出一笔事务；没有 output ready。
- `cim_odata_oc_mask/cim_odata_phase`：与该结果对应的入口标签。

72-bit 总线是四个独立 signed18，不能整体解释为 signed72。无写完成、busy、错误、原始 SRAM 读数据或 Context ID 端口。

### 6.3 子乘法器和 Weight Fusion

每 OC 有 32 个 slice。slice s 的权重 byte 和四个 2-bit digit 为：

```text
B_s  = row[256*c + 8*s +: 8]，s=0..31
d[t] = B_s[2*t +: 2]，t=0..3
```

每 slice 有四个 2×4 子乘法器，使用以下连接：

```text
W2:
  slice_s = Σ_(t=0..3) d[t] × ACTdigit[4*s+t]

W4:
  a0 = ACTdigit[2*s]
  a1 = ACTdigit[2*s+1]
  slice_s = d0*a0 + 4*d1*a0 + d2*a1 + 4*d3*a1

W8:
  a = ACTdigit[s]
  slice_s = d0*a + 4*d1*a + 16*d2*a + 64*d3*a
```

ACTdigit[j] 指 `cim_idata[4*j +: 4]`。W2 四个子乘法器各使用不同 activation；W4 每两个共用一个；W8 四个共用一个。

符号按第 3 章处理。四种 signed/unsigned 组合的子乘积统一为 signed7，U2×U4 最大 45。左移前先扩宽，禁止窄位移后再扩宽导致位丢失。

### 6.4 本地归约与结果宽度

```text
32×signed13 → 16×signed14 → 8×signed15
            → 4×signed16 → 2×signed17 → 1×signed18
```

每个 slice 先扩为 signed13，五层加法全部组合完成。子乘积、slice 和树层之间没有寄存器；四个 OC 并行。

```text
S[c,p] = Σ_(j=0..K_row-1) W[c,j] × ACTdigit[j,p]
```

无效 OC 的 18-bit 结果为 0，其输出 mask 位为 0。最大正向局部 Phase Sum 为 UINT W8：`32*255*15=122400`，signed18 足够。

Macro 不做 activation Phase 位权左移、saturation、rounding 或 Requant。A16 的单次输出仍只是一个 4-bit digit 的局部和。

### 6.5 一拍计算与结果事务

```text
issue = !reset && cim_ren && (|cim_oc_mask)

上升沿 n：R_in 采样 ACT/地址/station/precision/signed/phase/mask
n 到 n+1：SRAM 读取或 Hold 选择
          → 2×4 子乘法 → Weight Fusion → 五层本地归约
上升沿 n+1：R_out 输出四路结果和标签；刷新请求同时建立 Hold
```

ACT 只有一组 512-bit 入口寄存器，四个 OC 共用。不能加入第二组 ACT 对齐、独立当前计算 weight_r1、product/slice/归约层间寄存以改变一拍契约。Hold 和 SRAM 状态不计作额外计算流水级，但也不能借它们增加延迟。

```text
in_valid[n]  = issue[n]
out_valid[n] = in_valid[n-1] = issue[n-1]
```

这里 n 表示相应上升沿更新后的状态。结果数据/标签仅在完成有效事务时更新，其他周期保持最近值；valid 每拍更新，不能重复上一笔。

连续 `cim_ren=1` 表示每个上升沿一笔新请求。mask=0 不发射、不刷新 Hold、不产生新结果；本沿 mask=0 或 ren=0 不能取消先前请求在本沿完成的结果/Hold。

n+1 沿的寄存器更新完成后，Macro 结果可见。普通下游上升沿寄存器在 n+2 采样该值；n+1 输出可见与下游 n+2 捕获不能混为一件事。

### 6.6 Weight Hold

Hold 保存完整 1024-bit 原始行、8-bit 地址和 valid，不保存 ACT 门控后的权重，也不丢弃被 mask 的 OC 权重。

- station=1：本次 SRAM 新读出直接参与 n→n+1 的组合计算，在 n+1 同时捕获结果并建立 Hold。
- station=0：关闭本次阵列读，复用最新先行刷新建立的有效 Hold；请求地址必须等于 Hold 地址。
- n 的 station=1 Row5 可紧接 n+1 的 station=0 Row5，无需气泡；B 的组合区间使用 n+1 同沿建立的 Hold。
- 合法性判断须考虑本沿完成的先行刷新，不能只检查沿前的旧 hold_valid/旧地址。
- reset 或任意合法整行写清除 hold_valid；写后和复位后首个计算必须 station=1。
- 无自动命中读取、隐式刷新或自动地址递增；无效/错误地址 Hold 复用是上游非法请求。
- Hold 与 activation、OC mask 无关；精度解析仍使用当前入口事务，但 Cluster 级配置切换限制继续有效。

```text
n    接受 A：station=1，Row5
n+1  输出 A，提交 Row5 Hold；同时接受 B：station=0，Row5
n+2  输出 B
```

Hold 可由 SRAM 读出锁存或独立寄存实现，不能增加当前计算延迟。沿 n+1 捕获 A 时须使用沿前稳定的 A 输入，B 的入口更新不得污染 A。

### 6.7 整行写与读写互斥

基线按单访问 SRAM 资源、加载和计算分阶段设计，不要求双端口或 read-during-write。

```text
最后计算 issue 在 n
n+1：结果/Hold 捕获，禁止同时写入
n+2：最早允许整行写
n+3：最早允许写后 station=1 计算
n+4：新计算结果可见
```

写许可按采样沿前状态判断：`reset=0 && cim_wen=1 && cim_ren=0 && in_valid=0`。沿前 out_valid=1 可以是已经完成的独立出口结果，允许下游在本沿采样它并同时写 SRAM，不等于计算仍占用阵列。

相邻沿允许连续整行写；每笔在对应沿采样地址/数据，下一沿前须完成提交。最后写在 w，最早 w+1 发射 station=1；适配层须保证读到新内容。任意合法写使 Hold 无效，不清其他 SRAM 行。

若 reset 打断尚未完成提交的整行写，该行内容无保证，使用前重写；不承诺回滚。reset 不主动清 SRAM，也不设 256 个行有效位；上游保证被读行已初始化。

同时读写、在途运算未完成即写、未初始化行、无效 Hold、非法精度/Phase 均不提供正确结果保证；没有静默仲裁或自动重试。

### 6.8 SRAM 与时序适配

```text
Tclk >= Tcq_in + Tread_select + Tmul_sign + Tweight_fusion
        + Treduce + Twire + Tsetup_out + Tuncertainty
```

地址从 n 沿后给出，读数据必须在 n+1 的出口 setup 之前足够早稳定，以完成全部本地组合计算。仅在 n+1 沿后才提供本次读数据的同步读接口不满足当前契约。

实际 SRAM 的透明窗口、读出锁存、PVT 最大/最小路径、setup/hold、时钟不确定性均须单独签核。达不到频率时应报告具体瓶颈，不能默默恢复八拍或变长等待。

## 7 Macro 间级联与可配置归约树

### 7.1 级联接口与计算语义

八个 Macro 的每个本地 OC c 分别进入对应 c 的跨 Macro 归约路径，即四套并行归约通路：

```text
Macro0.OCc ─┐
Macro1.OCc ─┤
...         ├─ 可配置树 ─→ group g 的 OCc Phase Sum
Macro7.OCc ─┘
```

仅允许合并同一逻辑 `(M, OC, K Tile, phase)` 的不同 K 段。某组里各 Macro 的“本地 OC0”必须映射为同一个逻辑输出 OC，而其他组可将本地 OC0 映射到另一个逻辑输出。

宏之间不串接 `cim_idata`，不共享 Weight Hold；每个 Macro 独立读取自己的权重行。共享的是 Cluster 选择后的逻辑 ACT 来源、发射事件及匹配标签。

### 7.2 物理树与 split 编码

```text
                       t0 {0..7}
                 /                    \
          t1 {0..3}                  t2 {4..7}
          /       \                  /       \
     t3 {0,1}   t4 {2,3}       t5 {4,5}   t6 {6,7}
       / \         / \           / \         / \
      M0 M1       M2 M3         M4 M5       M6 M7
```

`reduce_split_mask[i]` 对应 ti；文字编码均按 `[6:0]`，最右位是根 bit0。从根向下遍历：

- 当前节点 split=0：整棵子树构成一个输出归约组，停止访问后代。
- split=1：继续访问左右子树；二叶节点拆分后各 Macro 独立输出。
- 未被访问的所有后代位必须为 0。

规范配置数递推为 `F(1)=1, F(2)=2, F(4)=5, F(8)=26`。不是所有 7-bit 值都合法。

```text
0000000：{0,1,2,3,4,5,6,7}
0000001：{0,1,2,3} / {4,5,6,7}
0000111：{0,1} / {2,3} / {4,5} / {6,7}
1111111：{0}/{1}/{2}/{3}/{4}/{5}/{6}/{7}
1000101：{0,1,2,3} / {4,5} / {6} / {7}
```

### 7.3 tree enable 和 OC mask 的不同职责

```text
participate[m] = macro_en_mask[m] && (|macro_oc_mask[4*m +: 4])
expected_m[m]  = consume_fire && participate[m]
cim_ren_m     = consume_fire && participate[m]
```

Cluster 可以按上式在 ren 中排除全零 OC mask；Macro 自身也会通过 issue 条件排除它。

- tree 决定哪些 Macro 属于同一 K 归约组。
- macro_en 决定当前请求中哪些物理 Macro 被使用。
- OC mask 决定这些 Macro 中哪些本地 OC 有贡献。
- 组内 idle Macro 不参加结果 valid 等待；整组没有实际参与者时不输出。
- 每个 OC 仅累加该 OC 有效的成员；屏蔽位置贡献为 0。

推导出的数值/有效位关系为：

```text
R_g[c,p] = Σ_(m∈g 且 participate[m] 且 oc_mask[m,c]) S_m[c,p]
lane_valid_g[c] = OR_(m∈g) (participate[m] && oc_mask[m,c])
group_valid = OR_c lane_valid_g[c]
```

该 OR 只能表示“存在有效贡献”，不能证明该 OC 的 K 覆盖完整。若某 lane 需要完整 K，而某成员的对应 OC 被屏蔽，上游必须保证这确为合法 Tail/零贡献，否则属于映射错误。

### 7.4 K Slot 覆盖约束

同组不同 K 分段使用不同 Slot，避免重复计算 K。同一 group 的 K_parallel 按实际有效且不重叠的 K 覆盖计算，不由 tree 的叶子总数单独决定。

不同输出组可以共用 Slot，表示相同 ACT 用于不同 OC；这些组不互相归约。K Tail 补零、不同组共享 ACT 和组内重复 K 是三个不同概念。

标准 K=256 映射：

```text
W2：split=0000111，EN=FF
    slot=[0,1,0,1,0,1,0,1]
    group={0,1}/{2,3}/{4,5}/{6,7}，4组×4OC=16OC

W4：split=0000001，EN=FF
    slot=[0,1,2,3,0,1,2,3]
    group={0..3}/{4..7}，2组×4OC=8OC

W8：split=0000000，EN=FF
    slot=[0,1,2,3,4,5,6,7]
    group={0..7}，1组×4OC=4OC
```

[T27] 的 K=128 映射保持上述 tree/Slot，仅改变 EN：

```text
W2：EN=55，有效成员 {0}/{2}/{4}/{6}，每组1×128，4组×4OC
W4：EN=33，有效成员 {0,1}/{4,5}，每组2×64，2组×4OC
W8：EN=0F，有效成员 {0,1,2,3}，单组4×32，1组×4OC
```

此时所有 ACT 示例仅使用 Plane 低 128 个 digit，高 512 bit 补零。一个 Tile K=128，`os_cnt=2` 表示两个完整 Tile 覆盖总 K=256，并非将单 Tile 改为 K=256。

### 7.5 归约宽度与两拍实现边界

逻辑加法层级为：

```text
Macro局部 signed18
  → 二成员 signed19
  → 四成员 signed20
  → 八成员 signed21
```

小组、单 Macro 和 bypass 输出均符号扩展为统一 signed21，每组四路。三层逻辑树并不要求三拍寄存；[T27] 采用总共两拍 Reduction。

**整合建议**：第一个 Reduction 寄存边界容纳二成员和四成员逻辑，第二边界完成八成员根合并及结果选择；小组和单 Macro 路径增加等效对齐，使所有 group 的当前 Phase 在同一 C(q+3) 出现。该分配不是来源已经验证的 RTL，仍需时序和不同 split 的实现检查。

若选择其他两拍分配，必须保持所有配置的相同延迟及 II=1。不能让 split 后的小组早一拍到达而继续使用未调整的标签。

### 7.6 外部标签与组号

Cluster 在实际发射时保存至少以下逻辑信息，不要求都做成新增外部 pin：

```text
事务有效、Context、K Tile、phase、precision/signed
tree/组映射、expected_m、各 Macro OC mask
末 Phase、末 Tile 及必要的输出映射
```

Macro 仅返回 phase 和本地 OC mask；Context/tree 标签留在 Cluster。一拍 Macro 标签延迟必须含全零 mask 气泡，不能套用历史八拍对齐。

归约级使用发射时快照检查所有 expected Macro 的对应结果，不使用当前外部 `cmd_i` 解释旧结果。reset 取消事务后，标签、结果等待和信用一起取消。

组按最小 macro_id 从小到大排序。全 idle 组是否占输出 group_id、S 深度位置如何打包，来源未充分定义。**整合建议**按 tree 的组次序保留固定槽，idle 组输出 invalid，避免随 enable 改变组号；正式组号/输出格式仍列为待冻结。数据流中的逻辑输出身份须稳定，即使地址、Slot 或合法映射逐命令改变也不能把不同输出累加到同一 Psum。

## 8 Command ACT 与数据流调度

### 8.1 三种模式

OS 保持 Psum；WS 保持一个逻辑 Weight Tile，连续处理 R=`ws_cnt` 个 activation Context；AS 保持 ACT Plane，连续处理 R=`as_cnt` 个不同权重/输出 Context。

```text
OS / WS：Context-major
  Ctx0.p0 → ... → Ctx0.p(P-1)
  → Ctx1.p0 → ... → Ctx1.p(P-1) → ...

AS：Phase-major
  Ctx0.p0 → Ctx1.p0 → ... → Ctx(R-1).p0
  → Ctx0.p1 → ... → Ctx(R-1).p1 → ...
```

一个逻辑 Context 的各 Phase 引用同一权重内容和 K/OC 配置。AS 中不同 Context 可以使用不同地址，但同一 Context 不能在高/低 Phase 换成不同逻辑权重。

### 8.2 无停顿发射次序公式

设 t 是 K Tile 编号、c 是 Context 编号、p 是 Phase 编号。对附录的 tile-major 示例：

```text
WS：q(t,c,p) = (t*R+c)*P+p
AS：q(t,c,p) = (t*P+p)*R+c
OS：R=1，q(t,0,p)=t*P+p
```

这是附录场景的无气泡日程；更一般的上层 M/OC 顺序不由本文件扩展定义。存在暂停时，上式给出相对顺序而不再直接表示绝对时钟号。

### 8.3 Command 与 ACT 解耦

- 每次实际发射消耗一条匹配的 Command，AS 复用已有 Plane 的拍也如此。
- Command 或 ACT 可先到，但必须配对到正确 Tile/Context/Phase 后才能发射。
- 被反压的 Command 保持 payload 和 valid；被反压的 ACT 保持数据和对应元信息。
- 当前 Plane 未就绪、Fusion/Psum 无空间、Macro 写入冲突或信用不足时停止新的发射。
- 停止新发射不能停止已接受 Macro 请求的完成，也不能提前释放它们关联的标签和容量。

Command 没有外部 Context ID/Phase 字段的情况下，输入顺序和内部计数必须唯一确定归属。ACT 没有独立 Tile/Plane tag pin 的情况下，同样需要正式定义隐式接收顺序。本文保留“按数据流顺序配对”的来源规则，但不声称现有字段表已完整定义任意乱序接收。

### 8.4 地址保持与阵列读取

WS 同一 Tile 内地址不变，可以在首笔 station=1 后使用 station=0，前提是各参与 Macro 已建立有效 Hold，且没有 reset/写入。

AS 的示例地址在 `0x20/0x21` 之间切换，单行 Hold 无法同时保留两个 Context 的权重，因此通常每次切换都要 station=1。仅“地址与本 Context 上次一样”不代表当前 Hold 仍保存它。

[T27] 所述参考 adapter 固定 station=1，即使地址不变也重新读 SRAM。WS/AS 的逻辑复用关系和减少物理 SRAM 读取次数必须分开验证。

## 9 Activation Fusion 与跨 Tile Psum

### 9.1 Fusion 和 Psum 是独立状态

Macro 间归约完成后，每个 `(context_idx, group_id, oc)` 获得一个 signed21 Phase Sum。Fusion 组合同一个完整 activation 的 digit；Psum 组合不同完整 K Tile。不能将尚未完成的低 digit 暂存直接写入活跃 Psum 条目。

对每个活跃 `(ctx,g)`：

- A8 原规格 LowFusion：4×32 bit，独立有效位，保存低 Phase 结果。
- Psum：4×32 bit，独立有效位和已完成 Tile 计数。
- A16 所需 Fusion 条目、位宽和端口组织应扩展定义；不能假定旧 A8 LowFusion 的描述已经覆盖四个 Phase。

### 9.2 A4 A8 A16 的形成方式

```text
A4:
  T = R0

A8:
  p0：LowFusion[ctx,g] = R0
  p1：T = LowFusion[ctx,g] + (R1 << 4)
      匹配完成后释放 LowFusion

A16:
  T = R0 + (R1 << 4) + (R2 << 8) + (R3 << 12)
```

**整合建议**：A16 使用独立 Fusion Context 保存尚未完成 Tile 的部分和及 phase-valid/下一 phase 状态；按顺序到达时可逐次累加 `R_p << (4p)`。最后 p3 才形成完整 T，释放 Fusion 状态并进入 Psum 更新。若支持其他 phase 到达顺序，则须保存各 phase 是否到达，不能仅依据 phase=3 就完成。

所有 shift 先扩宽，INT 按最高 digit 的符号扩展处理。A4 不需要 LowFusion；低 Phase 不更新跨 Tile Psum。

### 9.3 宽度与溢出

沿用 [B3]：Psum 对 INT/UINT 均限制在 signed32 存储范围。

```text
INT ：-2^31 <= Psum <= 2^31-1
UINT：0     <= Psum <= 2^31-1
```

加法和移位须先充分扩宽，再检查范围；不能先截为 32 bit，再用截断结果判断 overflow。UINT 不能借 bit31 表示更大的正数域。

统一 signed21 接口如不利用精度相关上界，`R3 << 12` 至少需要 signed33 的表达位宽；若再直接对四个不受模式约束的 signed21 输入求和，还需要求和保护位。实际合法模式的完整 Tile 最大值为 UINT W8A16、K=256 的 4,278,124,800，signed33 可表示该合法结果。

**整合建议**：Fusion 移位、求和及与 signed32 Psum 相加的临时通路统一采用 signed35，随后执行范围检查。该宽度是保守实现建议，不等于把 Psum 的架构范围扩展到 35 bit。A16 的实际寄存组织、面积和时序仍须冻结。

UINT 的最坏 Tile 增量与可保证不溢出的完整 Tile 次数为：

```text
P_tile_max = K_parallel × (2^bW-1) × (2^bA-1)
N_OS_max   = floor((2^31-1)/P_tile_max)
```

K_parallel=256 的七种精度数值见附录 C。`N_OS_max=0` 表示连一个全最大值 Tile 都不能保证落在 signed32 内，不表示该模式所有实际数据都非法。溢出后的饱和、终止或异常报告尚待冻结。

### 9.4 完整 Tile 的 Psum 更新

```text
完整 Tile T 有效：
  Psum[id] = (新 Context ? 0 : Psum[id]) + T
```

只有完成全部 Phase 的有效 Tile 才更新 Psum。每个 Tile 仅累加一次，按对应 Context/group/OC 寻址；不同 Context 或输出通道不合并。

A4 在唯一 p0 形成完整 T 后更新；A8 在 p1 与低 Phase 匹配并形成完整 T 后更新；A16 在 p0…p3 全部匹配并形成完整 T 后更新。低 Phase 只更新独立 Fusion 状态，不能提前写入 Psum。

每次完整 Tile 成功累加后推进该 Context/group 的已完成 Tile 计数。达到 `os_cnt` 后产生 raw Psum 就绪事件；单个 Tile 的更新不直接表示外部 Requant 向量完成。

### 9.5 容量 反馈和生命周期

```text
C_Psum_min      = N_P × 4 × 32 bit
C_LowFusion_min = N_L × 4 × 32 bit      // A8 基线
AS 下 N_L >= R × G                    // R 个 Context，各 G 个有效组
```

N_P 是同时存活的 Psum 条目数，按 `(ctx,g)` 计；N_L 是同时存活的 A8 Fusion 条目数。二者独立，不能共用同一物理条目覆盖同时活跃的值。[B3] 中出现的“40-bit TBD ×4 OC×4 psum×S”没有冻结，不替代上述 signed32 语义。

同一 Context 的后续 Phase 或后续 Tile 可以紧邻到达。若要维持 II=1，Fusion 和 Psum 存储必须支持所需读改写、写后读旁路或等效反馈。特别是 A4 同一 Context 每拍一完整 Tile，不能依赖一个无法连续反馈的 RAM 组织。

完成 `os_cnt` 个完整 Tile 的累加后，该 Context/group 的 raw Psum 就绪。其他 Context 不必同时完成；就绪值须保留至后续 Requant/输出可靠捕获，不能立即复用覆盖。

## 10 端到端流水与逐拍示例

### 10.1 4T 目标契约

[T27] 的计算流水为：

```text
Cq      实际发射到各有效 Macro，采样当前 Phase
C(q+1)  Macro R_out：4×signed18/有效 Macro 可见
C(q+2)  Reduction 第1个寄存边界
C(q+3)  Reduction 第2个寄存边界：4×signed21/输出组可见
C(q+4)  Fusion 状态更新；若全部 Phase 匹配则形成完整 T 并累加到 Psum
```

若 Cq 是某 Context 最后 K Tile 的最后 Phase，则 C(q+4) 沿后该 Context 的 raw Psum 就绪。低 Phase 在 C(q+4) 只更新 Fusion，不表示完整结果。

这与 Macro 的一拍定义一致：下游在 C(q+2) 捕获 C(q+1) 沿后可见的 Macro 结果。不能为了获得 4T 在同一沿把刚更新的寄存数据又当作已采样的新输入。

4T 不含 Command/ACT 的排队、输入旁路之外的前端寄存、Requant、输出拼装或 out_ready 等待。配置要求每级 II=1、资源已预留、无内部等待；当前 Cluster RTL 尚未据此验证。

### 10.2 A4 A8 A16 的单 Context 例子

```text
A4：p0@C0 → Macro@C1 → Reduction@C3 → raw Psum@C4

A8：p0@C0 → Macro@C1 → Reduction@C3 → LowFusion@C4
    p1@C1 → Macro@C2 → Reduction@C4 → 完整T/Psum@C5

A16：p0@C0 → Fusion低段@C4
     p1@C1 → Fusion低段@C5
     p2@C2 → Fusion低段@C6
     p3@C3 → 完整T/Psum@C7
```

此处均取一个 K Tile。多个 Tile 时，前面的完整 T 仅更新 Psum，不产生该输出的最终完成事件。

### 10.3 六组实例的公共条件

- 每个 K Tile=128，两个 Tile 时分别对应逻辑 K[0:127] 与 K[128:255]。
- Slot/split 使用第 7.4 节标准映射；EN 分别为 W2=0x55、W4=0x33、W8=0x0F。
- `macro_oc_mask=32'hFFFF_FFFF`；signed_en 可为 0 或 1，精度保持不变。
- 每条有效记录均有 `cmd_fire=1`，配置保持不等于 cmd_valid=0。
- 示范 Command/ACT 可同沿接收并实际发射，所有 ready 满足、无停顿。
- WS 每个发射 Phase 写入所属 Context 的 ACT；AS 仅每个 Phase 的首个 Context 写 ACT，其他 Context 复用。
- 单 Tile 地址 0x20；双 Tile 的 WS 地址为 0x20/0x30；AS 的两个 Context 分别为 0x20/0x21 和 0x30/0x31。

附录 A 用七种具体 precision 展开全部六组输入，不省略 A16 的 C8…C15。

### 10.4 输入到完成的通式

```text
P = bA/4
R = ws_cnt(WS) 或 as_cnt(AS)，纯 OS 取1
N = os_cnt × R × P
最后发射 = C(N-1)
最后 Context raw完成 = C(N+3)
C0到全部raw完成经过时间 = (N+3)T
```

若某 Context 的最后发射在 Cq，则其自身完成在 C(q+4)，不等待其他 Context。C0 至 C5 是经过 5T，不是把包含端点的 6 个标号当成 6T。

附录 A 的最后 Context 完成：

```text
例A1  os/ws/as=1/2/0：A4 C1→C5；A8 C3→C7；A16 C7→C11
例A2  os/ws/as=1/0/2：A4 C1→C5；A8 C3→C7；A16 C7→C11
例A3  os/ws/as=2/1/0：A4 C1→C5；A8 C3→C7；A16 C7→C11
例A4  os/ws/as=2/0/1：A4 C1→C5；A8 C3→C7；A16 C7→C11
例A5  os/ws/as=2/2/0：A4 C3→C7；A8 C7→C11；A16 C15→C19
例A6  os/ws/as=2/0/2：A4 C3→C7；A8 C7→C11；A16 C15→C19
```

### 10.5 各 Context 独立完成

相同 P 对应的精度共享以下时序：

```text
A1 WS 单Tile两Context：
  A4 ：Ctx0 C0→C4；  Ctx1 C1→C5
  A8 ：Ctx0 C1→C5；  Ctx1 C3→C7
  A16：Ctx0 C3→C7；  Ctx1 C7→C11

A2 AS 单Tile两Context：
  A4 ：Ctx0 C0→C4；  Ctx1 C1→C5
  A8 ：Ctx0 C2→C6；  Ctx1 C3→C7
  A16：Ctx0 C6→C10； Ctx1 C7→C11

A3/A4 双Tile单Context：
  A4 ：Ctx0 C1→C5
  A8 ：Ctx0 C3→C7
  A16：Ctx0 C7→C11

A5 WS 双Tile两Context：
  A4 ：Ctx0 C2→C6；   Ctx1 C3→C7
  A8 ：Ctx0 C5→C9；   Ctx1 C7→C11
  A16：Ctx0 C11→C15； Ctx1 C15→C19

A6 AS 双Tile两Context：
  A4 ：Ctx0 C2→C6；   Ctx1 C3→C7
  A8 ：Ctx0 C6→C10；  Ctx1 C7→C11
  A16：Ctx0 C14→C18； Ctx1 C15→C19
```

箭头左侧为该 Context 最后所需 Phase 的实际发射沿，右侧为其 raw Psum 就绪沿。out_valid_o 时刻另行计算。

## 11 反压 复位 门控与权重加载

### 11.1 Cluster 承担不可停顿 Macro 的接收责任

Macro 没有输入 ready 和输出 ready。Cluster 仅在预留了完整接收能力后才能发射，须计入：

- Macro 入口已接受且未输出的事务。
- Macro 出口已经可见、尚未被下游寄存边界捕获的事务。
- 两拍 Reduction 中的全部在途组结果和标签。
- Fusion/Psum 的活跃条目、反馈带宽和最终 raw 结果保存空间。
- 下游 Requant/输出阻塞时尚不能回收的 Context。

`out_ready_i=0` 时可以停止新发射，但已经发射的事务继续完成。不能仅关 `cim_ren` 就忽略下一拍 Macro 结果，也不能把 out_ready 直接连到 Macro 时钟门控。

信用深度和缓冲深度尚未冻结，应依据最大在途量、最大组数和反压边界确定。若内部 stage 可停顿，数据与标签同时保持，并由后续空间预留确保 Macro 返回不会丢失；无等待的 4T 只适用于第 10 章条件。

### 11.2 复位

高有效异步复位沿用 [M02]：

- Macro 清入口/出口 valid、输出数据/phase/mask、入口 ACT/控制和 Hold valid。
- Hold 数据本体可不复位，但无效时不得复用；SRAM 单元不复位。
- Cluster 清 Command/ACT 所属和有效状态、调度计数、归约标签、Fusion/Psum 有效状态及接收预留，不将复位前结果配对到复位后 Context。
- 复位取消所有在途计算；不能等待它们继续返回。
- 复位释放须同步，复位期间禁止计算/写入；首笔读使用 station=1。

Cluster 数据存储本体是否逐位清零由实现决定，但无效条目不可被当成零初始化以外的有效旧值使用。新 Psum Context 从零开始。

### 11.3 门控

采用 ICG 或低电平锁存使能后的门控，禁止任意组合使能直接 AND clock。异步复位不能依赖门控时钟才生效。

整个 Macro 共用时钟的活动条件可沿用：

```text
clock_active = !reset && (issue || cim_wen || in_valid || out_valid)
```

该条件经安全门控实现。最后请求在 n、结果 n+1 可见后，还要保留 n+2 边沿清除出口 valid。停止新发射不能取消旧请求结果/Hold 捕获或最后 valid 清除。

### 11.4 从计算切换到加载

每 Macro 的最早写时刻按第 6.7 节执行。若 Cluster 采用整个 Block 的加载阶段，还需确定是否等待 Reduction/Fusion/Psum 完成，以及旧 Context 是否仍会使用被替换权重。Macro 本地 n+2 可写不自动表示整个 Cluster Tile 已排空。

共享 preload 写地址不影响正式计算地址的采样。加载完成后相关 Macro Hold 全部失效，首次新计算重新读取。

### 11.5 物理电源边界

[B3] 的 SRAM 目标是 Dual-Rail、Deep-Retention；MAC 的描述同时出现“仅 Clock Gating”和“MTCMOS Power Gating TBD”。本文只保留已经定义的逻辑门控行为；memory/power wrapper 的 rail、隔离、Retention 进入/退出、唤醒和测试控制另行冻结。

逻辑 reset 不清 SRAM 的规则不等于电源切换后保证内容保留。电源域变化后的 SRAM/Hold 有效性由物理契约确定，不能复用未经保证的状态。

## 12 Requant 与外部结果输出

### 12.1 数学关系

沿用 [B3] 的对称 Weight 和非对称静态 Activation 关系：

```text
q_w = round(r_w/s_w)，z_w=0
q_x = round(r_x/s_x)+z_x
Y   = s_x*s_w*(Psum_raw - z_x*col_sum[j])
col_sum[j] = 当前输出 OC 在全部有效 K 范围内的整数权重和
```

跨多个 K Tile 时，col_sum 必须覆盖同一完整逻辑 K，不能只使用最后 Tile 的列和。

[B3] 说明 Requant 为 per-tensor 的非对称静态 INT8 量化，涉及上游 zero-point 和 s_y，s_x/s_w 为 FP32。输出精确公式、输入/输出 zero-point 分别如何提供、scale 的端口/存储、舍入方式、饱和范围、内部位宽和延迟尚未冻结，不能将本关系当成可直接实现的全部接口规格。

### 12.2 输出形状与 lane 有效位

每个深度位置最多八组、每组四 OC、每 OC 一字节：

```text
总数据位宽 = S × 8 × 4 × 8 = 256*S
总有效位宽 = S × 8 × 4     = 32*S

lane_index = (d*8+g)*4+c
requant_lane_valid_o[lane_index]
```

**整合建议**将对应数据字节映射为：

```text
requant_odata_o[8*lane_index +: 8] = requant_result[d,g,c]
```

该低位优先数据 packing 依据现有 lane-valid 索引补齐，正式 byte packing、group 压缩与 S 的含义仍须确认。Idle group、无效 depth、OC Tail 对应 lane-valid 为 0。

[B3] 后文的 `[S][4][4][8]` 与 128*S 位宽只支持四组，不能覆盖八组独立输出，因此本版以早先端口表及最大 32 OC 的 256*S 口径整合。

### 12.3 完成握手

只有要求的所有 K Tile 已完成 Psum、Requant 和本笔向量拼装后，才允许 `out_valid_o=1`。

```text
requant_fire = out_valid_o && out_ready_i
```

`out_valid_o && !out_ready_i` 时，数据、lane-valid 和存在的输出标签保持稳定。一次完整向量的成功握手表示该向量完成；S 深度向量可能等待其他 depth，不能把某个 Context 的 raw 就绪等同于该向量可发出。

基线完整向量协议不需要额外重复的 tile_done 事件。若 LSM 无法单拍接收 256*S bit，应由外部收集/拆拍，或另行冻结流式输出协议，不能直接把内部 raw_psum_valid 当成替代输出。

## 13 验证与实现状态

### 13.1 单 Macro 的来源报告

[M02] 报告日期为 2026-10-14：V0.2 SystemVerilog 一拍 RTL 已实现，使用 Icarus Verilog 13.0 进行了门控开/关各两个 seed，共四组正向回归。

- 接受 9,052 笔请求，校验 9,048 笔结果；4 笔在途请求按预期被异步复位取消。
- 每组完成 2×4 子乘法器的 256 种输入/符号组合穷举。
- 覆盖七种精度的 INT/UINT、全部合法 Phase、16 种 OC mask、连续发射与气泡、相邻刷新/复用、整行写与最早 n+2 写、写后 w+1 首读、空闲门控异步复位。
- 门控开启配置完成 13 类负向检查，包括非法精度/Phase、Hold 无效/地址错误、未初始化行、X/Z、读写冲突、提前写、写后/复位后非法复用。
- 使用独立完整整数点积 golden 和独立固定一拍 scoreboard；历史八拍 RTL 保存在 `singlemacro-v0.1` 标签。

工程相对位置为 `SingleMacro/verification/v0.2_results.json`、`SingleMacro/tb/tb_SingleMacro.sv`、`SingleMacro/scripts/run_tests.py`；最小包不含测试工程。本文仅归档来源报告，本次合并没有重新运行 RTL 或重新核验这些工程产物。

`SYNTHESIS` 分支编译/展开通过不等于逻辑综合。SRAM/ICG 工艺适配、逻辑综合、门级仿真、STA、形式验证及代码/功能覆盖率报告均未完成或未提供。

### 13.2 Cluster 尚需验证

[T27] 明确参考 adapter 仍是 OS 串行连接，WS/AS 和 4T 为目标时序说明；本文不会把文档时序扩展记作 Cluster RTL 实现成果。

Cluster 集成最低验证范围：

1. 全部 26 种 tree、不同 enable/OC mask、Idle 组、单 Macro bypass，所有路径保持两拍归约及正确标签。
2. 七种 precision、INT/UINT、最高 digit 符号、W2 独立 ACT 路由、K Tail、OC Tail。
3. K=128 与 K=256 标准映射；组内重复 Slot、缺失 K、跨 OC 错归约应被识别。
4. 共享地址广播和各 Macro 不同内容，逐 Command 地址/Slot 变化不串拍。
5. WS/AS 的 ACT 复用、同 Context 各 Phase 权重一致、单行 Hold 在地址交替时不能误命中。
6. AS 多 Context Fusion 容量与 A16 部分和隔离；Fusion 和 Psum 不互相覆盖。
7. A4 连续相同 Context 的 Tile 更新、相邻 A8/A16 Phase 的反馈/旁路；目标 II=1。
8. Psum signed32 上下界、UINT 禁止扩展 bit31 正数域、W8A16 的实际 overflow；移位前扩宽。
9. 完整 Tile 恰好累加一次、低 Phase 不写 Psum、已完成 Tile 计数及末 Tile 的完成条件。
10. Command/ACT 独立停顿、AS 保持 ACT 时仍发 Command、同沿写/消费、C0 首发旁路及排队延迟。
11. 下游持续反压时已发射结果全部被接收，标签/信用/输出向量不丢失不重复。
12. 复位取消在途结果、旧 Context 不混入新任务；读写切换满足 n+2 最早写。
13. Requant 的零点/列和/舍入/饱和、S 深度拼装、lane-valid 与外部握手稳定性。

### 13.3 MBIST 覆盖缺口

虽然 [B3] 文件名包含 MBIST，但所提供正文和图中没有可用的 MBIST 端口、算法、模式切换、完成/失败状态或 fail address 规范。不能由文件名推导已存在 MBIST 功能。

MBIST 是否纳入本 Block 的正式边界、测试访问如何与整行加载/计算互斥、是否使 Hold 失效、测试时钟和电源域行为，均列入第 14 章，未编造默认算法或寄存器。

## 14 尚待冻结的规格项

以下是完整设计落地前需要决策的接口/行为，不影响本文将已有材料组织为同一参考文件。

1. **共享计算读地址的最终签核**：本文采用 [T27] 8-bit 广播；[B3] 部分正文及 [M02] 集成映射曾按逐 Macro 地址描述。如要恢复八项独立地址，需修改 Command 宽度、packed 顺序、测试向量与 adapter。
2. **count 位宽及零值**：三个 count 当前仅 TB 用 16 bit；正式参数、上限、os_cnt=0 含义未冻结。
3. **ACT/Command 的隐式标签和接收次序**：现有 pin 不含显式 ACT Plane/Context tag，需定义允许的先到/后到顺序、队列深度和配对状态机。
4. **首拍同沿发射**：是否实现 ACT/Command 旁路；若无旁路，记录额外前端延迟，不修改实际发射起算的 4T 定义。
5. **Reduction 两拍的实际实现**：组合逻辑分配、所有 split/bypass 延迟对齐、标签和 mask 对齐以及 256 MHz 时序预算。
6. **Fusion/Psum 容量和端口**：A16 宽度、N_L/N_P、读改写旁路、反馈带宽、S/“4 psum”与 Context 的对应关系。
7. **结果信用和缓冲**：最大在途组数、输出停顿时保留的数据、什么时候停止 ready/发射、信用回收边界。
8. **Psum 溢出处理**：异常/饱和/终止策略，错误状态如何报告；不只定义范围检查。
9. **Command 错误处理**：非规范树、非法 Slot、重复 K、缺权重/ACT、读写冲突和配置切换错误的检测责任及报告方式。Macro 目前无错误 IO。
10. **Requant 参数和数值契约**：scale/zero-point/col_sum 的接口和作用范围、FP32/定点实现、舍入、输出 signed/unsigned INT8、饱和与延迟。
11. **外部输出格式**：S 的含义/取值、Idle group 是否压缩、数据 byte packing、depth 的 Context 对应和输出标签。
12. **正式 Weight Load/MBIST 接口**：TB preload 的产品化、访问仲裁、MBIST 算法/状态/错误地址和切换序列。
13. **Group 物理集成**：ACT Buffer 是每 Cluster 独立还是 Group 共用、广播 ready 汇总、最多同时激活 8 个 Cluster 与 16-Cluster 峰值的关系。
14. **电源/工艺适配**：SRAM Dual-Rail/Retention、MAC 是否 MTCMOS、隔离/唤醒/状态有效性及 SRAM/ICG 的实际工艺 IP。

## 15 来源追踪与旧定义替换

### 15.1 各章来源

- 第 2 章：规模沿用 [B3]；2×4 资源组织沿用 [M02]；8/16 Cluster 峰值差异为资源推导。
- 第 3 章：[M02] 七种编码与补码 digit 规则，和 [T27] 一致。
- 第 4 章：[T27] pin/TB struct 为基线，[B3] 提供正式输出语义；共享地址覆盖旧逐 Macro 读取描述。
- 第 5 章：[B3] ACT/Weight 容量、[M02] packing/Slot，Plane2/3 范围为算术纠错。
- 第 6 章：[M02] 单 Macro 正式功能基线，完整保留 IO、数值、Hold、时序、写入、SRAM 约束。
- 第 7 章：[B3] tree/K 映射与 [T27] K128 配置；signed19/20/21 沿用 [B3]；两拍物理划分和固定槽是明确标注的整合建议。
- 第 8 章：[B3]/[T27] Command/ACT 解耦与 OS/WS/AS；[M02] 原始行 Hold。
- 第 9 章：[B3] A8 Fusion/Psum/overflow，[T27]/[M02] A16 要求；完整 Tile 自动累加按本次用户修订采用，A16 状态及 signed35 为整合建议。
- 第 10 章及附录 A：[T27] 六组输入和 4T；使用等价公式生成七种具体精度的逐拍记录。
- 第 11 章：[M02] 复位/门控/读写；[B3]/[T27] Cluster 接收和电源目标。
- 第 12 章：[B3] Requant/LSM；256*S 是按最大八组四 OC 的尺寸纠正。
- 第 13 章：状态仅归档 [M02]/[T27]，本次未重新执行 RTL 验证；MBIST 缺口来自 [B3] 实际内容检查。

### 15.2 不再沿用的冲突写法

- `macro_oc_mask=16 bit`：替换为 32 bit，覆盖 8×4 OC。
- Cluster 共享 8-bit 与八项独立地址混写：本版统一共享 8-bit，保留最终签核项。
- Plane2/3 下界 2028：替换为 2048/3072。
- 最大八组输出却写 128*S：整合为 256*S，保留 group/S packing 待冻结项。
- 单 Macro 按八拍对齐：替换为一拍；标签和最早写入均以 v0.2 为准。
- 将三层归约理解为三拍：区分三层算术结构与两拍目标寄存实现。
- 将 4T raw Psum 当成 Requant 外部完成：拆开定义。
- 将地址不变当成已经 weight-stationary：必须实际使用合法 station=0。
- 将 [B3] 中关于不存在的第 7 章引用当成补充规范：本版使用 [T27]/[M02] 已实际给出的字段，不依赖缺失章节。

### 15.3 原始文件定位

```text
[B3]  D:/Document/2025B/anker/M1/output/CIM_Block_Spec_MBIST_v3.docx
[T27] D:/Document/2025B/anker/M1/output/CIM_Cluster_逐拍输入时序_v2.7.docx
[M02] D:/Document/2025B/anker/M1/Anker-CIM-Block-upload/macro/SingleMacro_SPEC_v0.2.md
```

本整合文件在工作区单独生成，三份来源保持不变。本文统一内容不构成工艺、频率、Cluster 实现或尚待冻结接口的签核。

## 附录 A 完整逐拍输入实例

以下所有记录的 Cq 都是实际发射沿；每行均有一条有效 Command。`write` 表示 ACT 握手接收当前 Plane，`hold` 表示 act_valid_i=0、复用 Buffer。若 ready 停顿，则保持输入并将后续实际发射整体顺延，不跳过记录。

各例统一可选 station=1 作为正确性基线，与 [T27] 参考 adapter 一致；若优化 WS 为 Hold 复用，遵循第 6.6 节，不由地址字段自动推导。输出均为 raw Psum，不含 Requant。

### A1 WS os 1 ws 2 as 0

每 Tile 的有效 K=128；单 Tile，总 K=128。

#### A1 precision 0 W2A4

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx1 p0  raddr=0x20  ACT=write A0(T0,Ctx1)
```

Ctx0 最后发射 C0，raw Psum C4；Ctx1 最后发射 C1，raw Psum C5；C0 至全部 raw 完成 5T。

#### A1 precision 1 W2A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0,Ctx0)
C2   T0 Ctx1 p0  raddr=0x20  ACT=write A0(T0,Ctx1)
C3   T0 Ctx1 p1  raddr=0x20  ACT=write A1(T0,Ctx1)
```

Ctx0 最后发射 C1，raw Psum C5；Ctx1 最后发射 C3，raw Psum C7；C0 至全部 raw 完成 7T。

#### A1 precision 2 W4A4

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx1 p0  raddr=0x20  ACT=write A0(T0,Ctx1)
```

Ctx0 最后发射 C0，raw Psum C4；Ctx1 最后发射 C1，raw Psum C5；C0 至全部 raw 完成 5T。

#### A1 precision 3 W4A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0,Ctx0)
C2   T0 Ctx1 p0  raddr=0x20  ACT=write A0(T0,Ctx1)
C3   T0 Ctx1 p1  raddr=0x20  ACT=write A1(T0,Ctx1)
```

Ctx0 最后发射 C1，raw Psum C5；Ctx1 最后发射 C3，raw Psum C7；C0 至全部 raw 完成 7T。

#### A1 precision 4 W4A16

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0,Ctx0)
C2   T0 Ctx0 p2  raddr=0x20  ACT=write A2(T0,Ctx0)
C3   T0 Ctx0 p3  raddr=0x20  ACT=write A3(T0,Ctx0)
C4   T0 Ctx1 p0  raddr=0x20  ACT=write A0(T0,Ctx1)
C5   T0 Ctx1 p1  raddr=0x20  ACT=write A1(T0,Ctx1)
C6   T0 Ctx1 p2  raddr=0x20  ACT=write A2(T0,Ctx1)
C7   T0 Ctx1 p3  raddr=0x20  ACT=write A3(T0,Ctx1)
```

Ctx0 最后发射 C3，raw Psum C7；Ctx1 最后发射 C7，raw Psum C11；C0 至全部 raw 完成 11T。

#### A1 precision 5 W8A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0,Ctx0)
C2   T0 Ctx1 p0  raddr=0x20  ACT=write A0(T0,Ctx1)
C3   T0 Ctx1 p1  raddr=0x20  ACT=write A1(T0,Ctx1)
```

Ctx0 最后发射 C1，raw Psum C5；Ctx1 最后发射 C3，raw Psum C7；C0 至全部 raw 完成 7T。

#### A1 precision 6 W8A16

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0,Ctx0)
C2   T0 Ctx0 p2  raddr=0x20  ACT=write A2(T0,Ctx0)
C3   T0 Ctx0 p3  raddr=0x20  ACT=write A3(T0,Ctx0)
C4   T0 Ctx1 p0  raddr=0x20  ACT=write A0(T0,Ctx1)
C5   T0 Ctx1 p1  raddr=0x20  ACT=write A1(T0,Ctx1)
C6   T0 Ctx1 p2  raddr=0x20  ACT=write A2(T0,Ctx1)
C7   T0 Ctx1 p3  raddr=0x20  ACT=write A3(T0,Ctx1)
```

Ctx0 最后发射 C3，raw Psum C7；Ctx1 最后发射 C7，raw Psum C11；C0 至全部 raw 完成 11T。

### A2 AS os 1 ws 0 as 2

每 Tile 的有效 K=128；单 Tile，总 K=128。

#### A2 precision 0 W2A4

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx1 p0  raddr=0x21  ACT=hold  A0(T0)
```

Ctx0 最后发射 C0，raw Psum C4；Ctx1 最后发射 C1，raw Psum C5；C0 至全部 raw 完成 5T。

#### A2 precision 1 W2A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx1 p0  raddr=0x21  ACT=hold  A0(T0)
C2   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0)
C3   T0 Ctx1 p1  raddr=0x21  ACT=hold  A1(T0)
```

Ctx0 最后发射 C2，raw Psum C6；Ctx1 最后发射 C3，raw Psum C7；C0 至全部 raw 完成 7T。

#### A2 precision 2 W4A4

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx1 p0  raddr=0x21  ACT=hold  A0(T0)
```

Ctx0 最后发射 C0，raw Psum C4；Ctx1 最后发射 C1，raw Psum C5；C0 至全部 raw 完成 5T。

#### A2 precision 3 W4A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx1 p0  raddr=0x21  ACT=hold  A0(T0)
C2   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0)
C3   T0 Ctx1 p1  raddr=0x21  ACT=hold  A1(T0)
```

Ctx0 最后发射 C2，raw Psum C6；Ctx1 最后发射 C3，raw Psum C7；C0 至全部 raw 完成 7T。

#### A2 precision 4 W4A16

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx1 p0  raddr=0x21  ACT=hold  A0(T0)
C2   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0)
C3   T0 Ctx1 p1  raddr=0x21  ACT=hold  A1(T0)
C4   T0 Ctx0 p2  raddr=0x20  ACT=write A2(T0)
C5   T0 Ctx1 p2  raddr=0x21  ACT=hold  A2(T0)
C6   T0 Ctx0 p3  raddr=0x20  ACT=write A3(T0)
C7   T0 Ctx1 p3  raddr=0x21  ACT=hold  A3(T0)
```

Ctx0 最后发射 C6，raw Psum C10；Ctx1 最后发射 C7，raw Psum C11；C0 至全部 raw 完成 11T。

#### A2 precision 5 W8A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx1 p0  raddr=0x21  ACT=hold  A0(T0)
C2   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0)
C3   T0 Ctx1 p1  raddr=0x21  ACT=hold  A1(T0)
```

Ctx0 最后发射 C2，raw Psum C6；Ctx1 最后发射 C3，raw Psum C7；C0 至全部 raw 完成 7T。

#### A2 precision 6 W8A16

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx1 p0  raddr=0x21  ACT=hold  A0(T0)
C2   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0)
C3   T0 Ctx1 p1  raddr=0x21  ACT=hold  A1(T0)
C4   T0 Ctx0 p2  raddr=0x20  ACT=write A2(T0)
C5   T0 Ctx1 p2  raddr=0x21  ACT=hold  A2(T0)
C6   T0 Ctx0 p3  raddr=0x20  ACT=write A3(T0)
C7   T0 Ctx1 p3  raddr=0x21  ACT=hold  A3(T0)
```

Ctx0 最后发射 C6，raw Psum C10；Ctx1 最后发射 C7，raw Psum C11；C0 至全部 raw 完成 11T。

### A3 WS os 2 ws 1 as 0

每 Tile 的有效 K=128；两个 Tile，总 K=256。

#### A3 precision 0 W2A4

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1,Ctx0)
```

Ctx0 最后发射 C1，raw Psum C5；C0 至全部 raw 完成 5T。

#### A3 precision 1 W2A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0,Ctx0)
C2   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1,Ctx0)
C3   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1,Ctx0)
```

Ctx0 最后发射 C3，raw Psum C7；C0 至全部 raw 完成 7T。

#### A3 precision 2 W4A4

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1,Ctx0)
```

Ctx0 最后发射 C1，raw Psum C5；C0 至全部 raw 完成 5T。

#### A3 precision 3 W4A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0,Ctx0)
C2   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1,Ctx0)
C3   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1,Ctx0)
```

Ctx0 最后发射 C3，raw Psum C7；C0 至全部 raw 完成 7T。

#### A3 precision 4 W4A16

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0,Ctx0)
C2   T0 Ctx0 p2  raddr=0x20  ACT=write A2(T0,Ctx0)
C3   T0 Ctx0 p3  raddr=0x20  ACT=write A3(T0,Ctx0)
C4   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1,Ctx0)
C5   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1,Ctx0)
C6   T1 Ctx0 p2  raddr=0x30  ACT=write A2(T1,Ctx0)
C7   T1 Ctx0 p3  raddr=0x30  ACT=write A3(T1,Ctx0)
```

Ctx0 最后发射 C7，raw Psum C11；C0 至全部 raw 完成 11T。

#### A3 precision 5 W8A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0,Ctx0)
C2   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1,Ctx0)
C3   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1,Ctx0)
```

Ctx0 最后发射 C3，raw Psum C7；C0 至全部 raw 完成 7T。

#### A3 precision 6 W8A16

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0,Ctx0)
C2   T0 Ctx0 p2  raddr=0x20  ACT=write A2(T0,Ctx0)
C3   T0 Ctx0 p3  raddr=0x20  ACT=write A3(T0,Ctx0)
C4   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1,Ctx0)
C5   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1,Ctx0)
C6   T1 Ctx0 p2  raddr=0x30  ACT=write A2(T1,Ctx0)
C7   T1 Ctx0 p3  raddr=0x30  ACT=write A3(T1,Ctx0)
```

Ctx0 最后发射 C7，raw Psum C11；C0 至全部 raw 完成 11T。

### A4 AS os 2 ws 0 as 1

每 Tile 的有效 K=128；两个 Tile，总 K=256。

#### A4 precision 0 W2A4

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1)
```

Ctx0 最后发射 C1，raw Psum C5；C0 至全部 raw 完成 5T。

#### A4 precision 1 W2A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0)
C2   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1)
C3   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1)
```

Ctx0 最后发射 C3，raw Psum C7；C0 至全部 raw 完成 7T。

#### A4 precision 2 W4A4

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1)
```

Ctx0 最后发射 C1，raw Psum C5；C0 至全部 raw 完成 5T。

#### A4 precision 3 W4A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0)
C2   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1)
C3   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1)
```

Ctx0 最后发射 C3，raw Psum C7；C0 至全部 raw 完成 7T。

#### A4 precision 4 W4A16

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0)
C2   T0 Ctx0 p2  raddr=0x20  ACT=write A2(T0)
C3   T0 Ctx0 p3  raddr=0x20  ACT=write A3(T0)
C4   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1)
C5   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1)
C6   T1 Ctx0 p2  raddr=0x30  ACT=write A2(T1)
C7   T1 Ctx0 p3  raddr=0x30  ACT=write A3(T1)
```

Ctx0 最后发射 C7，raw Psum C11；C0 至全部 raw 完成 11T。

#### A4 precision 5 W8A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0)
C2   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1)
C3   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1)
```

Ctx0 最后发射 C3，raw Psum C7；C0 至全部 raw 完成 7T。

#### A4 precision 6 W8A16

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0)
C2   T0 Ctx0 p2  raddr=0x20  ACT=write A2(T0)
C3   T0 Ctx0 p3  raddr=0x20  ACT=write A3(T0)
C4   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1)
C5   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1)
C6   T1 Ctx0 p2  raddr=0x30  ACT=write A2(T1)
C7   T1 Ctx0 p3  raddr=0x30  ACT=write A3(T1)
```

Ctx0 最后发射 C7，raw Psum C11；C0 至全部 raw 完成 11T。

### A5 WS os 2 ws 2 as 0

每 Tile 的有效 K=128；两个 Tile，总 K=256。

#### A5 precision 0 W2A4

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx1 p0  raddr=0x20  ACT=write A0(T0,Ctx1)
C2   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1,Ctx0)
C3   T1 Ctx1 p0  raddr=0x30  ACT=write A0(T1,Ctx1)
```

Ctx0 最后发射 C2，raw Psum C6；Ctx1 最后发射 C3，raw Psum C7；C0 至全部 raw 完成 7T。

#### A5 precision 1 W2A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0,Ctx0)
C2   T0 Ctx1 p0  raddr=0x20  ACT=write A0(T0,Ctx1)
C3   T0 Ctx1 p1  raddr=0x20  ACT=write A1(T0,Ctx1)
C4   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1,Ctx0)
C5   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1,Ctx0)
C6   T1 Ctx1 p0  raddr=0x30  ACT=write A0(T1,Ctx1)
C7   T1 Ctx1 p1  raddr=0x30  ACT=write A1(T1,Ctx1)
```

Ctx0 最后发射 C5，raw Psum C9；Ctx1 最后发射 C7，raw Psum C11；C0 至全部 raw 完成 11T。

#### A5 precision 2 W4A4

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx1 p0  raddr=0x20  ACT=write A0(T0,Ctx1)
C2   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1,Ctx0)
C3   T1 Ctx1 p0  raddr=0x30  ACT=write A0(T1,Ctx1)
```

Ctx0 最后发射 C2，raw Psum C6；Ctx1 最后发射 C3，raw Psum C7；C0 至全部 raw 完成 7T。

#### A5 precision 3 W4A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0,Ctx0)
C2   T0 Ctx1 p0  raddr=0x20  ACT=write A0(T0,Ctx1)
C3   T0 Ctx1 p1  raddr=0x20  ACT=write A1(T0,Ctx1)
C4   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1,Ctx0)
C5   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1,Ctx0)
C6   T1 Ctx1 p0  raddr=0x30  ACT=write A0(T1,Ctx1)
C7   T1 Ctx1 p1  raddr=0x30  ACT=write A1(T1,Ctx1)
```

Ctx0 最后发射 C5，raw Psum C9；Ctx1 最后发射 C7，raw Psum C11；C0 至全部 raw 完成 11T。

#### A5 precision 4 W4A16

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0,Ctx0)
C2   T0 Ctx0 p2  raddr=0x20  ACT=write A2(T0,Ctx0)
C3   T0 Ctx0 p3  raddr=0x20  ACT=write A3(T0,Ctx0)
C4   T0 Ctx1 p0  raddr=0x20  ACT=write A0(T0,Ctx1)
C5   T0 Ctx1 p1  raddr=0x20  ACT=write A1(T0,Ctx1)
C6   T0 Ctx1 p2  raddr=0x20  ACT=write A2(T0,Ctx1)
C7   T0 Ctx1 p3  raddr=0x20  ACT=write A3(T0,Ctx1)
C8   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1,Ctx0)
C9   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1,Ctx0)
C10  T1 Ctx0 p2  raddr=0x30  ACT=write A2(T1,Ctx0)
C11  T1 Ctx0 p3  raddr=0x30  ACT=write A3(T1,Ctx0)
C12  T1 Ctx1 p0  raddr=0x30  ACT=write A0(T1,Ctx1)
C13  T1 Ctx1 p1  raddr=0x30  ACT=write A1(T1,Ctx1)
C14  T1 Ctx1 p2  raddr=0x30  ACT=write A2(T1,Ctx1)
C15  T1 Ctx1 p3  raddr=0x30  ACT=write A3(T1,Ctx1)
```

Ctx0 最后发射 C11，raw Psum C15；Ctx1 最后发射 C15，raw Psum C19；C0 至全部 raw 完成 19T。

#### A5 precision 5 W8A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0,Ctx0)
C2   T0 Ctx1 p0  raddr=0x20  ACT=write A0(T0,Ctx1)
C3   T0 Ctx1 p1  raddr=0x20  ACT=write A1(T0,Ctx1)
C4   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1,Ctx0)
C5   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1,Ctx0)
C6   T1 Ctx1 p0  raddr=0x30  ACT=write A0(T1,Ctx1)
C7   T1 Ctx1 p1  raddr=0x30  ACT=write A1(T1,Ctx1)
```

Ctx0 最后发射 C5，raw Psum C9；Ctx1 最后发射 C7，raw Psum C11；C0 至全部 raw 完成 11T。

#### A5 precision 6 W8A16

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0,Ctx0)
C1   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0,Ctx0)
C2   T0 Ctx0 p2  raddr=0x20  ACT=write A2(T0,Ctx0)
C3   T0 Ctx0 p3  raddr=0x20  ACT=write A3(T0,Ctx0)
C4   T0 Ctx1 p0  raddr=0x20  ACT=write A0(T0,Ctx1)
C5   T0 Ctx1 p1  raddr=0x20  ACT=write A1(T0,Ctx1)
C6   T0 Ctx1 p2  raddr=0x20  ACT=write A2(T0,Ctx1)
C7   T0 Ctx1 p3  raddr=0x20  ACT=write A3(T0,Ctx1)
C8   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1,Ctx0)
C9   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1,Ctx0)
C10  T1 Ctx0 p2  raddr=0x30  ACT=write A2(T1,Ctx0)
C11  T1 Ctx0 p3  raddr=0x30  ACT=write A3(T1,Ctx0)
C12  T1 Ctx1 p0  raddr=0x30  ACT=write A0(T1,Ctx1)
C13  T1 Ctx1 p1  raddr=0x30  ACT=write A1(T1,Ctx1)
C14  T1 Ctx1 p2  raddr=0x30  ACT=write A2(T1,Ctx1)
C15  T1 Ctx1 p3  raddr=0x30  ACT=write A3(T1,Ctx1)
```

Ctx0 最后发射 C11，raw Psum C15；Ctx1 最后发射 C15，raw Psum C19；C0 至全部 raw 完成 19T。

### A6 AS os 2 ws 0 as 2

每 Tile 的有效 K=128；两个 Tile，总 K=256。

#### A6 precision 0 W2A4

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx1 p0  raddr=0x21  ACT=hold  A0(T0)
C2   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1)
C3   T1 Ctx1 p0  raddr=0x31  ACT=hold  A0(T1)
```

Ctx0 最后发射 C2，raw Psum C6；Ctx1 最后发射 C3，raw Psum C7；C0 至全部 raw 完成 7T。

#### A6 precision 1 W2A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx1 p0  raddr=0x21  ACT=hold  A0(T0)
C2   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0)
C3   T0 Ctx1 p1  raddr=0x21  ACT=hold  A1(T0)
C4   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1)
C5   T1 Ctx1 p0  raddr=0x31  ACT=hold  A0(T1)
C6   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1)
C7   T1 Ctx1 p1  raddr=0x31  ACT=hold  A1(T1)
```

Ctx0 最后发射 C6，raw Psum C10；Ctx1 最后发射 C7，raw Psum C11；C0 至全部 raw 完成 11T。

#### A6 precision 2 W4A4

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx1 p0  raddr=0x21  ACT=hold  A0(T0)
C2   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1)
C3   T1 Ctx1 p0  raddr=0x31  ACT=hold  A0(T1)
```

Ctx0 最后发射 C2，raw Psum C6；Ctx1 最后发射 C3，raw Psum C7；C0 至全部 raw 完成 7T。

#### A6 precision 3 W4A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx1 p0  raddr=0x21  ACT=hold  A0(T0)
C2   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0)
C3   T0 Ctx1 p1  raddr=0x21  ACT=hold  A1(T0)
C4   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1)
C5   T1 Ctx1 p0  raddr=0x31  ACT=hold  A0(T1)
C6   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1)
C7   T1 Ctx1 p1  raddr=0x31  ACT=hold  A1(T1)
```

Ctx0 最后发射 C6，raw Psum C10；Ctx1 最后发射 C7，raw Psum C11；C0 至全部 raw 完成 11T。

#### A6 precision 4 W4A16

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx1 p0  raddr=0x21  ACT=hold  A0(T0)
C2   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0)
C3   T0 Ctx1 p1  raddr=0x21  ACT=hold  A1(T0)
C4   T0 Ctx0 p2  raddr=0x20  ACT=write A2(T0)
C5   T0 Ctx1 p2  raddr=0x21  ACT=hold  A2(T0)
C6   T0 Ctx0 p3  raddr=0x20  ACT=write A3(T0)
C7   T0 Ctx1 p3  raddr=0x21  ACT=hold  A3(T0)
C8   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1)
C9   T1 Ctx1 p0  raddr=0x31  ACT=hold  A0(T1)
C10  T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1)
C11  T1 Ctx1 p1  raddr=0x31  ACT=hold  A1(T1)
C12  T1 Ctx0 p2  raddr=0x30  ACT=write A2(T1)
C13  T1 Ctx1 p2  raddr=0x31  ACT=hold  A2(T1)
C14  T1 Ctx0 p3  raddr=0x30  ACT=write A3(T1)
C15  T1 Ctx1 p3  raddr=0x31  ACT=hold  A3(T1)
```

Ctx0 最后发射 C14，raw Psum C18；Ctx1 最后发射 C15，raw Psum C19；C0 至全部 raw 完成 19T。

#### A6 precision 5 W8A8

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx1 p0  raddr=0x21  ACT=hold  A0(T0)
C2   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0)
C3   T0 Ctx1 p1  raddr=0x21  ACT=hold  A1(T0)
C4   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1)
C5   T1 Ctx1 p0  raddr=0x31  ACT=hold  A0(T1)
C6   T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1)
C7   T1 Ctx1 p1  raddr=0x31  ACT=hold  A1(T1)
```

Ctx0 最后发射 C6，raw Psum C10；Ctx1 最后发射 C7，raw Psum C11；C0 至全部 raw 完成 11T。

#### A6 precision 6 W8A16

```text
C0   T0 Ctx0 p0  raddr=0x20  ACT=write A0(T0)
C1   T0 Ctx1 p0  raddr=0x21  ACT=hold  A0(T0)
C2   T0 Ctx0 p1  raddr=0x20  ACT=write A1(T0)
C3   T0 Ctx1 p1  raddr=0x21  ACT=hold  A1(T0)
C4   T0 Ctx0 p2  raddr=0x20  ACT=write A2(T0)
C5   T0 Ctx1 p2  raddr=0x21  ACT=hold  A2(T0)
C6   T0 Ctx0 p3  raddr=0x20  ACT=write A3(T0)
C7   T0 Ctx1 p3  raddr=0x21  ACT=hold  A3(T0)
C8   T1 Ctx0 p0  raddr=0x30  ACT=write A0(T1)
C9   T1 Ctx1 p0  raddr=0x31  ACT=hold  A0(T1)
C10  T1 Ctx0 p1  raddr=0x30  ACT=write A1(T1)
C11  T1 Ctx1 p1  raddr=0x31  ACT=hold  A1(T1)
C12  T1 Ctx0 p2  raddr=0x30  ACT=write A2(T1)
C13  T1 Ctx1 p2  raddr=0x31  ACT=hold  A2(T1)
C14  T1 Ctx0 p3  raddr=0x30  ACT=write A3(T1)
C15  T1 Ctx1 p3  raddr=0x31  ACT=hold  A3(T1)
```

Ctx0 最后发射 C14，raw Psum C18；Ctx1 最后发射 C15，raw Psum C19；C0 至全部 raw 完成 19T。

## 附录 B 规范树编码

编码为 `[6:0]`，最右位 bit0 是根；花括号里的数字均为物理 macro_id。enable/OC mask 独立作用，不改变这份拓扑枚举。

```text
0000000  {0,1,2,3,4,5,6,7}
0000001  {0,1,2,3} / {4,5,6,7}
0000011  {0,1} / {2,3} / {4,5,6,7}
0000101  {0,1,2,3} / {4,5} / {6,7}
0000111  {0,1} / {2,3} / {4,5} / {6,7}
0001011  {0} / {1} / {2,3} / {4,5,6,7}
0001111  {0} / {1} / {2,3} / {4,5} / {6,7}
0010011  {0,1} / {2} / {3} / {4,5,6,7}
0010111  {0,1} / {2} / {3} / {4,5} / {6,7}
0011011  {0} / {1} / {2} / {3} / {4,5,6,7}
0011111  {0} / {1} / {2} / {3} / {4,5} / {6,7}
0100101  {0,1,2,3} / {4} / {5} / {6,7}
0100111  {0,1} / {2,3} / {4} / {5} / {6,7}
0101111  {0} / {1} / {2,3} / {4} / {5} / {6,7}
0110111  {0,1} / {2} / {3} / {4} / {5} / {6,7}
0111111  {0} / {1} / {2} / {3} / {4} / {5} / {6,7}
1000101  {0,1,2,3} / {4,5} / {6} / {7}
1000111  {0,1} / {2,3} / {4,5} / {6} / {7}
1001111  {0} / {1} / {2,3} / {4,5} / {6} / {7}
1010111  {0,1} / {2} / {3} / {4,5} / {6} / {7}
1011111  {0} / {1} / {2} / {3} / {4,5} / {6} / {7}
1100101  {0,1,2,3} / {4} / {5} / {6} / {7}
1100111  {0,1} / {2,3} / {4} / {5} / {6} / {7}
1101111  {0} / {1} / {2,3} / {4} / {5} / {6} / {7}
1110111  {0,1} / {2} / {3} / {4} / {5} / {6} / {7}
1111111  {0} / {1} / {2} / {3} / {4} / {5} / {6} / {7}
```

## 附录 C UINT 最坏增量与 signed32 累加上限

以下以 K_parallel=256、全部 UINT 元素达到最大值计算。N_OS_max 统计完整 Tile 的安全累加次数，不是周期数；不是对任意输入数据的强制任务上限。

```text
W2A4   precision=0  P_tile_max=11,520  N_OS_max=186,413
W2A8   precision=1  P_tile_max=195,840  N_OS_max=10,965
W4A4   precision=2  P_tile_max=57,600  N_OS_max=37,282
W4A8   precision=3  P_tile_max=979,200  N_OS_max=2,193
W4A16  precision=4  P_tile_max=251,654,400  N_OS_max=8
W8A8   precision=5  P_tile_max=16,646,400  N_OS_max=129
W8A16  precision=6  P_tile_max=4,278,124,800  N_OS_max=0
```

W8A16 的 4,278,124,800 已超过 signed32 最大正数 2,147,483,647。必须先在宽临时值中完成 Fusion 再判 overflow，不能依靠 32-bit 截断或 UINT reinterpretation 隐藏该问题。
