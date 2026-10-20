"""Generate the repository specification and 42 explicit input/operation tables."""
from pathlib import Path
from buffer_schedule import COUNTS, NAMES, ABITS, STANDARD_DELAY, sequence, standard_rows, groups, issue_cycle, external_rows

REPO = Path(__file__).resolve().parents[4]

BODY = """# CIM Cluster 输入与计算说明

本仓库包含八个 SingleMacro 组成的 Cluster 仿真参考实现。外部按 A0→A3 连续输入完整 ACT，首 slice 与 i_cmd 同拍；收齐 ACT 及所需 Context 地址后，内部按 WS/AS 顺序分发。ACT buffer 为4096 bit。WS 在 tmp 写入前做 fusion、下一拍做 Psum acc；AS 先写 tmp，下一拍选择 fusion 或 acc。各 Context 独立输出 raw signed32，未包含 requant。

## 逐拍输入时序文档

[下载 CIM_Cluster_逐拍输入时序_v2.7.docx](docs/CIM_Cluster_逐拍输入时序_v2.7.docx)：包含 Cluster 输入 pin、七种精度的 ACT slice、WS/AS/OS 配置、权重地址、逐拍操作和输入到输出时延。

## 目录与运行

```text
docs/                           逐拍输入时序 Word 文档
RTL/
  macro/rtl/                    SingleMacro 计算与权重存储
  macro/tb/                     单 Macro testbench
  cluster/cluster_tb/
    sv_code/                    Cluster 参考实现与 testbench
    py/                         仿真入口和数据检查
    data/                       配置、操作和时延 CSV
    log/                        回归日志和检查结果
vcs-rtl/                        VCS 编译列表与 Makefile
```

从仓库根目录执行：

```text
python RTL/cluster/cluster_tb/py/run_regression.py --gate-unit --mixed-context --full-act --latency-audit --log regression_act_frame_default.log
```

ModelSim 的 vlib/vlog/vsim 需在 PATH 中。脚本从任意工作目录调用均可，脚本将 SV、Macro RTL 和 Python 检查器复制到仓库外的本地仿真目录，work、波形、CSV 和日志均在该副本内生成；副本不纳入 Git。默认位置为仓库同级 cluster_tb_work/local_sim/<日志名>，可用 --sim-dir 指定仓库外目录。仓库 data/log 保存经检查的结果。VCS 入口位于 vcs-rtl；测试参数及其他运行方法见 [cluster_tb README](RTL/cluster/cluster_tb/README.md)。

## 术语与 Context

**Context 是同一输出 channel 内独立保存、独立输出的一项计算任务。** Context 编号 c 对应 Psum[c] 的深度索引；不同 Context 的结果不相加。OUTPUT_BUFFER_DEPTH 是每个 channel 可保存的 Context 数。

- WS、ws=2：同一 Tile 的权重复用两次，两个不同完整 ACT 分别生成 Ctx0、Ctx1。
- AS、as=2：同一完整 ACT 配合两个分别提交的权重地址，分别生成 Ctx0、Ctx1。
- OS、os=2：每个 Context 内累加两个 K Tile；最终 Ctx0、Ctx1 仍分别输出。

OC 是 Macro 内的四个输出之一；归约组 group 与局部 OC 共同组成逻辑 channel，lane=4×group+OC。Tile 是一次 K 分块，os_cnt 为每个 Context 的 Tile 数。Slice A0..A3 是 ACT 每个元素的连续4-bit位段；一个 Plane 将256个元素的同一 Slice 打包为1024 bit。Slot 是 Macro 从一个 Plane 中选择的 K_row 个 digit 位段。

Descriptor 是 cmd_i 携带的配置和权重地址。外部接受是 cmd_valid_i&&cmd_ready_o；内部发射是 ACT buffer 向 Macro 提交一次计算，二者有各自的周期。Bit fusion 将不同 Slice 的点积移位相加；acc 将同一 Context 的不同 K Tile 相加。tmp 是每 OC 唯一的中间结果寄存器，Psum 是按 Context 寻址的历史。raw 是未经 requant 的 signed32 结果；ICG 是集成时钟门控单元。

## Cluster 接口

方向以 Cluster 为视角。

| 信号 | 方向与位宽 | 语义 |
|---|---|---|
| clock / reset | 输入，各 1 bit | 上升沿时钟，高有效异步复位 |
| cmd_i | 输入，131 bit | 每个 Tile/Context 的完整 descriptor，含共享权重地址 |
| cmd_valid_i / cmd_ready_o | 输入 / 输出，各 1 bit | Command 接受握手 |
| act_data_i | 输入，1024 bit | 一个 Plane，含256个4-bit digit；首个命令接受沿为A0，随后连续采样A1..A(P−1) |
| weight_wen_i | 输入，8 bit | 预加载时选择写入的 Macro |
| weight_waddr_i | 输入，8 bit | 预加载行号 |
| weight_wdata_i | 输入，8192 bit | 八个 Macro 各一条 1024-bit 权重行 |
| psum_data_o | 输出，1024 bit | 32 个 channel 的 raw signed32 结果 |
| out_valid_o | 输出，32 bit | 每个 OC 一位的单拍发布脉冲：该 OC 的 raw 结果写回时置位一拍，下游无反压 |

ACT 没有独立握手信号。`cmd_fire=cmd_valid_i&&cmd_ready_o` 仅表示外部 descriptor 被接受。

- WS/单 Context：每个 Tile、每个 Context 发送一次 i_cmd+A0，随后 P−1 拍连续提供剩余 Slice，P=A位宽/4。
- AS：每个 Tile 仅加载一次完整 ACT；Ctx0 的 i_cmd 与 A0 同拍。Ctx1..Ctx(R−1) 分别通过后续 Command 提供自己的地址，可与 A1..A3 重叠；这些地址命令不重新加载 A0。所有 Context 的公共配置相同。
- 首命令尚未接受时保持 Command+A0。首命令接受后，剩余 ACT Slice 每拍固定接收，与后续 cmd_valid/cmd_ready 无关。没有 ACT valid/ready pin。
- 收齐完整 ACT 及 AS 的全部 Context 地址后，下一拍开始内部发射。内部 phase 从 act_buffer[1024×phase+:1024] 读取，再按 slot 分给 Macro。
- 单个4096-bit ACT buffer；当前包完成内部发射后，下一拍可接受下一包。内部发射期间不加载下一完整 ACT。

A16、WS、ws=2：C0 为 Ctx0 的 i_cmd+A0，C1/A1、C2/A2、C3/A3；C4..C7 内部分发 Ctx0；C8 接受 Ctx1 的 i_cmd+A0，C9..C11 接收后续 Slice，C12..C15 内部分发 Ctx1。

A16、AS、as=2：C0 为 Ctx0 的 i_cmd+A0，C1 为 Ctx1 的 i_cmd+A1，C2/A2、C3/A3；C4..C11 按 A0/Ctx0、A0/Ctx1、A1/Ctx0、A1/Ctx1、A2/Ctx0、A2/Ctx1、A3/Ctx0、A3/Ctx1 发射。例中地址20/21由外部分别提供，硬件不自动递增。

## Descriptor

| 字段 | 位宽 | 定义 |
|---|---:|---|
| os_cnt | 16 | 每个 Context 的完整 K Tile 数，最小 1 |
| ws_cnt | 16 | WS 复用的 Context 数，最小 1 |
| as_cnt | 16 | AS 复用的 Context 数，最小 1 |
| reduce_split_mask | 7 | 物理归约树 split 配置，bit0 为根 |
| macro_en_mask | 8 | bit m 使能 Macro m 的贡献 |
| macro_oc_mask | 32 | bit 4*m+c 使能 Macro m 的 OC c |
| weight_cim_raddr | 8 | 八个 Macro 共用的权重读地址，不自动递增 |
| act_slot_sel | 24 | 每个 Macro 一个 3-bit slot 编号 |
| precision | 3 | 0..6 的精度编码 |
| signed_en | 1 | 0=UINT×UINT，1=INT×INT |

`ws>1,as=1` 为 WS；`as>1,ws=1` 为 AS；`ws=as=1` 为单 Context。不支持 ws/as 同时大于 1。一个批次内 precision、符号、counts、split、mask、slot 固定，地址按每条外部 Command 采样并保留到内部发射。

## 精度与 ACT slice

| precision | W / A | K_row=256/W | phase 数 | ACT 顺序 |
|---:|---|---:|---:|---|
| 0 | W2A4 | 128 | 1 | A0 |
| 1 | W2A8 | 128 | 2 | A0、A1 |
| 2 | W4A4 | 64 | 1 | A0 |
| 3 | W4A8 | 64 | 2 | A0、A1 |
| 4 | W4A16 | 64 | 4 | A0、A1、A2、A3 |
| 5 | W8A8 | 32 | 2 | A0、A1 |
| 6 | W8A16 | 32 | 4 | A0、A1、A2、A3 |

`A0=ACT[3:0]`，`A1=ACT[7:4]`，`A2=ACT[11:8]`，`A3=ACT[15:12]`。`act_data_i[4*k+:4]` 是第 k 个 digit。INT 仅最高有效 slice 按 signed4 解释，其余为 unsigned4；UINT 全部为 unsigned4。

一个完整 ACT 的数值为 `Σ_p digitA[p]×2^(4p)`。权重由 2-bit digit 重组，INT 的最高有效权重 digit 为 signed2，其余为 unsigned2。

## Macro 与权重存储

每个 Macro 包含 256 条 1024-bit 权重行；每行四个 OC，各占 256 bit。共享读地址选中八个独立 SRAM 的同一行号，各 Macro 的权重内容独立。

SingleMacro 接受一个 ACT digit phase 后，下一拍给出四路 signed18 局部和，II=1。`cim_ren` 控制本拍计算，`cim_oc_mask` 选择 OC；内部 `cim_phase` 随当前 ACT slice 推进。

同地址且 Hold 有效时 `cim_station=0`，复用已保存的权重行；首次读取、换地址或该 Macro 写权重后使用 `cim_station=1` 刷新。预加载和计算按 testbench 分阶段执行。详细 Macro 接口与数值结构见 [SingleMacro 说明](RTL/macro/README.md)。

## Slot 与标准 K128 映射

Macro m 从 Plane 的 `slot[m]×K_row` 起读取 K_row 个 digit。每个归约组中，有效 Macro 的 slot 不重叠。附录每个 Tile 的有效 K 为 128，ACT 使用低 128 个 digit，高 512 bit 补零。

| 权重精度 | slot[0]..slot[7] | split_mask | EN | 物理终点 |
|---|---|---|---|---|
| W2 | [0,1,0,1,0,1,0,1] | 7'h07 | 8'h55 | pair |
| W4 | [0,1,2,3,0,1,2,3] | 7'h01 | 8'h33 | quad |
| W8 | [0,1,2,3,4,5,6,7] | 7'h00 | 8'h0F | root |

OC mask 为 `32'hFFFF_FFFF`。物理终点由 split 决定，不因某些 Macro 未启用而改变树深。channel=`4*group+OC`，group 按物理组从左到右编号。

## 归约与时延

归约只合并同一输出、同一 Context/Tile/phase 的 Macro 贡献。不同 Context、group 和 OC 不相加。根节点为 bit0，左右 quad 为 bit1/2，四个 pair 为 bit3..6；bit=1 表示拆分，bit=0 表示本节点合并。未访问的后代 split 位为 0，共 26 种规范编码。

归约终点从向父级转发 DFF 前取数。pair 终止时关闭相应 t3..t6；quad 终止时关闭相应 t1/t2；仅继续归约时打开转发 DFF。根结果进入通用 tmp，无额外 root-only 输出级。

| 归约终点 | Macro 发射 | tmp 捕获 / WS fusion | AS fusion、acc、Psum 写回或输出 |
|---|---|---|---|
| 叶子 / pair | Cq | C(q+2) | C(q+3) |
| quad | Cq | C(q+3) | C(q+4) |
| root | Cq | C(q+4) | C(q+5) |

标准 W2/W4/W8 从末次内部发射到 raw 完成为3T/4T/5T。每个 OC 的结果在自身终点写回时立即独立发布，`out_valid_o[oc]` 置位一拍；混合树浅层 OC 不等深层，无整 Context 装配等待。外部 ACT 收集、地址命令等待及包间接收时间需另计。

## tmp bit fusion 与 Psum acc

每个 channel=4×group+OC 只有一个 tmp 数据寄存器，以及深度为 OUTPUT_BUFFER_DEPTH 的 Psum buffer。每 OC 共用一套 fusion 和一套 acc 组合块，所有 Context 共享；同一 OC 每拍最多更新一个 Context entry。不同 OC 可独立处理各自到达的 Context。

令 R 为当前原始归约 slice，P[c] 为 Context c 的 Psum。WS/单 Context 的 tmp 保存当前 Tile 的融合前缀；AS 的 tmp 保存当前原始 R。

- WS/单 Context：A0 在 C(q+D−1) 用 R 覆盖 tmp；A1..A3 在写 tmp 前计算 `tmp+(R<<(4*phase))`。C(q+D) 消费这个 tmp；os=1 的最后 phase 直接输出，Psum 关闭；os>1 的最后 phase 将首 Tile 的 tmp 填充 P[c]，后续 Tile 执行 `P[c]+tmp`。非最后 phase 不写 Psum。
- AS：先在 C(q+D−1) 把 R 写入唯一 tmp，C(q+D) 更新当前 P[c]。首 Tile/A0 填充；后续 Tile/A0 做 `P[c]+tmp`；A1..A3 做 `P[c]+(tmp<<(4*phase))`。因此 os=1 的 A8/A16 也使用 P[c] 保存交错 Context 的 fusion 历史，但不启用跨 Tile acc；os=1 的 A4 直接从 tmp 输出，不写 Psum。

WS 的 fusion 与 acc 分属 tmp 两侧的相邻流水级，同一结果不串联经过这两个加法器。WS 的归约末级逻辑与 fusion 在 tmp 前可能形成串联路径，需要 STA。AS 在 tmp 后每拍只选择 fusion 或 acc；未使用组合块的两个输入均隔离为零。WS 处理旧 tmp 的 acc 时，可以同时融合下一条归约数据并写入同一个 tmp，DFF 上升沿使用旧值。

AS 的相邻 slice 间隔为 n 个有效发射周期，n=as_cnt；相邻 Tile 的同一 Slice 间隔为 max(P,n)+n×P，P=A位宽/4；包含下一包的 ACT/地址收集时间。OC 并行计算，不乘 OC 数。

## Buffer 深度与 ICG

OUTPUT_BUFFER_DEPTH 默认16，仅设置每 OC 的 Psum Context entry 数；tmp 每 OC 固定一个。Context 数不超过 min(OUTPUT_BUFFER_DEPTH,MAX_CONTEXTS)，MAX_CONTEXTS=16。RTL 最小深度1，完整六种标准配置需要至少2。输出逐 OC 发布，无输出反压。

首条 Command 接受时锁定深度掩码：os>1 或 AS 的 A8/A16 需要 Psum，仅开放低 max(ws,as) 个 entry；高地址 entry 整批关闭。WS/单 Context 的 os=1、AS A4 的 os=1 全部关闭 Psum。掩码保持至全部 Context 的有效 channel 发布完成。

`tmp_input_cg_en` 在 tmp 捕获前一拍寄存。`psum_cg_en[d][l]` 在 tmp 捕获时按已对齐的 Context/phase 标签寄存，供下一拍的 Psum 写回：AS 每个有效 phase 选当前 Context，WS 仅 os>1 的最后 phase 选当前 Context。每 OC 的 Psum 门控请求至多一位有效，其他深度保持。ICG 使用 MacroClockGate 模型，ASIC 需映射工艺库 cell。

复位清除控制、valid、标签和状态，不清除权重 SRAM。最终 RAW 为 signed32；参考计算使用 longint 避免中间截断，最终溢出时报错。

## 六种配置与验证

| 附录 / case | os | ws | as | 调度 |
|---|---:|---:|---:|---|
| A1 / 1 | 1 | 1 | 1 | 单 Tile、单 Context |
| A2 / 2 | 1 | 1 | 2 | 单 Tile、AS 两个 Context |
| A3 / 3 | 1 | 2 | 1 | 单 Tile、WS 两个 Context |
| A4 / 4 | 2 | 1 | 1 | 两 Tile、单 Context |
| A5 / 5 | 2 | 2 | 1 | 两 Tile、WS 两个 Context |
| A6 / 6 | 2 | 1 | 2 | 两 Tile、AS 两个 Context |

WS/单 Context 顺序为 Tile→Context→phase；AS 为 Tile→phase→Context。C0 为首个外部 i_cmd+A0 的接受沿。令 R=max(ws,as)、P=A位宽/4，D 为内部路径延迟；无外部空拍时：

- WS/单 Context：第 t 个 Tile、第 c 个 Context 的包起点 S=(t×R+c)×2P；ACT Aphase 在 C(S+phase) 接收，内部在 C(S+P+phase) 发射。
- AS：L=max(P,R)，第 t 个 Tile 包起点 S=t×(L+R×P)；第 c 个地址命令在 C(S+c)，ACT Aphase 在 C(S+phase)，内部在 C(S+L+phase×R+c) 发射。
- 整批末次内部发射：WS 为 C(os×R×2P−1)，AS 为 C(os×(L+R×P)−1)；最后 raw 再加 D。地址命令有空拍时按实际接受沿顺延。

默认回归为1368个 Cluster case，另有208个归约门控、24个混合Context和12个4096-bit ACT定向case；检查140个 Context 输出周期和480个标准运算事件。EN=FF 时每符号在七种 precision 下的合法 split 数为1、1、16、16、16、25、25，要求每组有效 K<256。

验证包含 Command 停顿、完整 ACT 加载后外部 ACT 变化时的 buffer 复用、ICG 时钟、关闭 DFF 保持和高地址深度关闭。实现为仿真参考 adapter，未进行综合/STA/门级功耗验证，未包含 requant。

## Cluster 数据 DFF 位置

以下按当前 SV 的声明位宽统计，D=OUTPUT_BUFFER_DEPTH；longint 为64 bit。范围限 Cluster adapter 与 reduce tree，八个 SingleMacro 的内部 ACT/weight/计算寄存器另计。这是静态功能数据存储的 bit 数，不是综合后的最终 cell 数。时钟门控只停止更新，不减少已实例化的 DFF 数量。

| 位置 | 实例或数组 | 数量×位宽 | 数据 DFF bit |
|---|---|---|---:|
| 完整 ACT 保存 | act_buffer | 4×1024 | 4096 |
| pair 转发级 | t3..t6 的 result_q | 4节点×4 OC×19 | 304 |
| quad 转发级 | t1/t2 的 result_q | 2节点×4 OC×20 | 160 |
| 唯一 tmp | tmp_result | 32 OC×64 | 2048 |
| Context Psum | psum[d][l] | D×32 OC×64 | 2048D |
| 输出数据保持 | raw_data | 32 OC×32 | 1024 |
| 合计 | 不含控制/标签/计数器 | 7632+2048D | D=16时40400 |

归约树 root 没有独立转发 DFF；fusion 与 acc 是组合块，二者之间使用唯一 tmp，没有额外 tmp 历史数组或 acc 中间 buffer。raw_data 是现有输出保持寄存器，与 tmp/Psum 分开计数。

AS 地址表 context_address 为8×MAX_CONTEXTS bit，默认128 bit，计入控制。另有 ACT Slice 有效位与接收计数。其余控制包括 valid、phase/Context/Tile 标签、Command 流水、批次状态、权重 Hold 地址/有效位及 ICG 请求等控制寄存器。Psum 写请求为32D bit、深度掩码为D bit、tmp请求为32 bit；reduce tree 的有效节点总使能为6 bit、逐OC请求为24 bit，另有两级48-bit控制流水。参考 adapter 的 int/完整 descriptor 标签和验证计数不作为优化后的控制面积估算。MacroClockGate 内部的 enable_latched 是 latch，不计为 DFF；未使用组合信号也不计存储。

## tb_Cluster 测试 case

测试入口为 [tb_Cluster.sv](RTL/cluster/cluster_tb/sv_code/tb_Cluster.sv)。

**一个 case 的含义：** 调用一次 `run_case`，按固定参数跑完一批完整计算，依次经过四个阶段：

1. **权重预加载：** 按本 case 的 Tile 数和 Context 数，把所有用到的权重行写入对应地址，预加载完成后才开始计算。
2. **输入发射：** 外部发送 os×r 条 Command；WS发送os×r个完整ACT，AS发送os个完整ACT。每个ACT为P个连续Plane。收齐后内部按WS（Tile→Context→phase）或AS（Tile→phase→Context）发射os×r×P次计算。
3. **逐拍监视：** 三个独立监视器（数值记分板、运算历史记分板、时钟门控记分板）全程比对 DUT 与独立参考模型。
4. **结果核对：** 检查每个 OC 脉冲的到达时刻、数值与同 OC 的 Context 顺序，最后确认全部 lane 均已发布且批次关闭。

一个 case 内 precision、符号、split、EN/OC mask、slot、counts、pattern 全部固定；case 之间不复位；权重保持状态可保留，批次配置、Context 计数和状态有效性按批次重新建立。case 行为由 SEED 决定，可精确重现。

### 默认参数

| 参数 | 默认值 | 含义 |
|---|---|---|
| EN_MASK | 8'hFF | 八个 Macro 全部使能 |
| OC_MASK | 32'hFFFF_FFFF | 32 个 OC 全部使能 |
| OS_TILES | 1 | suite 1 的 Tile 数（1..14） |
| PATTERNS | 6 | suite 1 使用的数据 pattern 数 |
| OUTPUT_BUFFER_DEPTH | 16 | 每 channel Context 状态深度 |
| SEED | 32'h19E2_A407 | pattern 0 的 xorshift 种子 |

七种精度均测试 UINT×UINT 和 INT×INT；不包含混合符号乘法。

### 默认回归的四类 suite（共 1368 case）

| suite | 名称 | case 数 | (os,ws,as) | Context 数 | pattern | 压力注入 |
|---:|---|---:|---|---|---|---|
| 1 | split 穷举 | 1200 | (OS_TILES,1,1)=(1,1,1) | 1 | 0..5 | pattern 0 的 case 插入 Command 空拍 |
| 2 | 六种标准配置 | 84 | A1..A6 | 1..2 | 0 | 无额外空拍，先接收后发射 |
| 3 | Command 空拍与多 Context 交错 | 28 | WS (2,r,1)、AS (2,1,r) | 6 | 0 | 空拍 |
| 4 | 三 Tile 极值与历史保持 | 56 | WS (3,r,1)、AS (3,1,r) | 3 | 4、5 | 空拍 |

合计 `1200+84+28+56=1368`。pattern 编号见下文“六种输入数据 pattern”；各类的展开与检查重点如下。

#### suite 1：split 穷举（1200 case）

**目的：** 用全部 26 种规范归约树覆盖各种 Macro 分组与归约终点组合的数值正确性。

case 按三个维度展开：

1. **配置：** 从 7-bit split_mask 的 128 个值中取 26 种规范树，再按每个归约组 `K=有效 Macro 数×(256/W)<256` 筛出合法 split。使用 `(os,ws,as)=(OS_TILES,1,1)`，默认单 Tile 单 Context；组内有效 Macro 按 Macro 编号分配不重叠 slot，编号从 0 开始。
2. **符号：** 每个合法 split 运行 UINT×UINT 与 INT×INT 两种符号。EN=FF 时合法 split 数见下表，共 200 个配置。
3. **数据：** 每个配置运行 6 种数据 pattern，得 `200×6=1200` 个 case。pattern 0 的 case 在每个完整ACT包前插入 (Tile+Context)%3 个空拍；AS 后续地址命令前另插入 Context%3 个空拍。已开始的 ACT A1..A3 连续接收。

| precision | W/A | 每符号合法 split | 两种符号×6 pattern case 数 |
|---:|---|---:|---:|
| 0 | W2A4 | 1 | 12 |
| 1 | W2A8 | 1 | 12 |
| 2 | W4A4 | 16 | 192 |
| 3 | W4A8 | 16 | 192 |
| 4 | W4A16 | 16 | 192 |
| 5 | W8A8 | 25 | 300 |
| 6 | W8A16 | 25 | 300 |

每个配置的 precision、符号、split、EN、OC、slot 和各组 K 记录在 [split_cases.csv](RTL/cluster/cluster_tb/data/split_cases.csv)，不逐行记录 pattern 与其他三类 suite。`data/buffer_cycle_cases.csv` 的 1200 个组合是这 200 个配置再展开六种 WS/AS/OS 调度后的逻辑时序清单，与本 suite 的 1200 个数据 pattern 仿真 case 含义不同。

#### suite 2：六种标准配置（84 case）

**目的：** 在标准 K128 映射（上文 W2/W4/W8 的 split、EN、slot 表，OC 全开）下检查附录 A 的无停顿逐拍时序。

- 展开：7 种精度×2 种符号×6 种 `(os,ws,as)`，依次为 `(1,1,1)`、`(1,1,2)`、`(1,2,1)`、`(2,1,1)`、`(2,2,1)`、`(2,1,2)`，对应附录 A1..A6；每 Tile K=128，ACT 高 512 bit 补零。
- 数据：固定随机 pattern 0。
- 发射：不注入额外 Command 空拍；核对完整 ACT 接收、AS 地址收集、内部发射的实际周期与上文包时序公式。包内内部连续发射，包间需要接收下一完整ACT。
- 副产物：本 suite 的每个运算写回拍选一个有效 channel 写入 [buffer_operations.csv](RTL/cluster/cluster_tb/data/buffer_operations.csv)，默认回归共 480 条（对应 84 个 case 的运算事件），记录操作类型、tmp、fusion/acc 操作数、结果与完成标志；`--latency-audit` 时由独立观察器把 140 个无停顿 Context 输出周期写入 [latency_audit.csv](RTL/cluster/cluster_tb/data/latency_audit.csv)（每精度×符号下六配置共 10 个 Context，7×2×10=140）。

#### suite 3：Command 空拍与多 Context 交错（28 case）

**目的：** 让多个 Context 的各 OC 结果同时在途，检查同 OC 按 Context 顺序逐拍发布与结果顺序。

- 展开：7 种精度×2 种符号×WS/AS。Context 数 `r=min(6,16,OUTPUT_BUFFER_DEPTH)`，默认 6；WS 用 `(2,r,1)`，AS 用 `(2,1,r)`。
- 空拍：完整 ACT 包前插入 (Tile+Context)%3 个空拍；AS 的后续地址命令前插入 Context%3 个空拍。ACT 后续 Slice 固定连续接收。
- 数据：固定随机 pattern 0。

#### suite 4：三 Tile 极值与历史保持（56 case）

**目的：** 在三 Tile×三 Context 交错与空拍条件下，检查 fusion/acc 历史不被后续写入覆盖，覆盖符号极值位型的组合。

- 展开：7 种精度×2 种符号×WS/AS×pattern 4/5。os=3，Context 数 `r=min(3,OUTPUT_BUFFER_DEPTH)`，默认 3；WS 用 `(3,r,1)`，AS 用 `(3,1,r)`。
- 数据：pattern 4/5 按元素在 lo/hi 间交替，ACT 和 weight 使用各自带偏移的元素索引，乘积符号由配对关系决定；不能保证同一 case 全部乘积同号。
- 压力：空拍注入方式与 suite 3 相同。

### 六种输入数据 pattern

pattern 同时决定 ACT 和 weight 的取值，各按自身精度位数采样。令 INT 的 hi=2^(b-1)−1、lo=−2^(b-1)（b 为该侧位宽），UINT 的 hi 为全 1、lo 为 0：

| pattern | ACT | weight | 覆盖目的 |
|---:|---|---|---|
| 0 | xorshift 伪随机位模式（SEED） | 同 ACT | 随机覆盖 |
| 1 | 全 0 | 全 0 | 零输入 |
| 2 | hi | hi | 单一极值位型（INT 最大正整数、UINT 全 1） |
| 3 | lo | lo | 另一侧极值位型（INT 最小负整数、UINT 全 0） |
| 4 | 偶数 lo、奇数 hi | 偶数 lo、奇数 hi | 各自索引上的 lo/hi 交替 |
| 5 | 偶数 lo、奇数 hi | 偶数 hi、奇数 lo | weight 交换 lo/hi 的交替 |

交替项的 index 是数据生成函数的元素索引，不是输入周期：ACT 的 index=digit 序号 k+7×Context 序号+Tile 序号（AS 复用 Context 复制 Ctx0 的 ACT）；weight 的 index=K_row 内序号 j+7×Macro 序号+3×OC 序号+Tile 序号+11×预加载 Context 序号（WS/单 Context 恒为 0）。

UINT W8A16 的 ACT 另外取模 `32768/os`，使全正极值和不超出 raw signed32；这部分 case 不覆盖完整 UINT16 数值范围。golden 结果一旦超出 signed32 直接报错，没有 requant 或饱和处理。

### 每个 case 检查什么

| 类别 | 内容 |
|---|---|
| 数值与有效通道 | 用完整 ACT/weight 整数独立计算点积（longint 无中间截断），逐 channel 比较 out_valid_o 脉冲与发布值；检查 OC mask、同 OC 的 Context 顺序，输出无丢失、重复、乱序 |
| 发射与输入 | WS 的 Tile→Context→phase、AS 的 Tile→phase→Context 发射顺序；权重地址 `8'h20+16*Tile`（AS 再加 Context 号）；逐 digit 比对 DUT 实际采样的 ACT Plane；完整ACT加载后改变外部ACT，确认内部发射逐digit使用act_buffer；首Command被阻塞时保持Command+A0，后续Slice连续采样 |
| 到达时延 | 每个 channel 按自身归约终点在末次内部发射后3T/4T/5T 写回并独立发布 out_valid_o 脉冲，不提前、不迟到；混合树各通道分别到达、分别发布 |
| 中间运算状态 | 逐 phase 检查 WS 唯一 tmp 的融合前缀、AS 的 Context Psum 历史；仅 WS/单 Context os=1 和 AS A4 os=1 全关 Psum；AS 同拍 fusion/acc 二选一，WS fusion 在 tmp 前、acc 在 tmp 后；未用加法器的两个输入隔离为零 |
| 时钟门控与保持 | 独立预测 唯一 tmp 输入/Psum 的 ICG 使能并比对实际门控时钟；被门控 DFF 数据保持不变；os>1 批次的高地址 Context entry 整批关闭 |
| 发布与批次边界 | 每个 OC 写回即发布一拍，lane 数据保持到该 OC 下次发布，同 OC 按 Context 顺序；权重复用覆盖计数非零；结束时检查全部 lane 已发布、批次关闭、无多余输出，tmp/fusion/acc 各路由与门控路径覆盖齐全 |

### 运行、参数作用范围与结果

从仓库根目录运行默认回归、归约门控单测和独立时延核对：

```text
python RTL/cluster/cluster_tb/py/run_regression.py --gate-unit --mixed-context --full-act --latency-audit --log regression_act_frame_default.log
```

| 参数 | 默认 | 作用范围 |
|---|---|---|
| `--en` / `--oc` | ff / ffffffff | 只改 suite 1 的 EN/OC mask。改 EN 会重新筛选合法 split（K 筛选按 EN 计算，不因关闭 OC 放宽）；suite 2..4 仍用标准 K128 映射与 OC 全开 |
| `--os` | 1 | 只改 suite 1 的 Tile 数（OS_TILES，1..14）；suite 2..4 的 os 固定为 1/2/3 |
| `--patterns` | 6 | 只改 suite 1 使用前 N 种 pattern；suite 2/3 固定 pattern 0，suite 4 固定 pattern 4/5，均不受影响 |
| `--depth` | 16 | OUTPUT_BUFFER_DEPTH，全局每 OC Context 状态深度，限 2..16；suite 3/4 的 r 按其截断，不足 3 时 suite 4 按可用深度运行 |
| `--seed` | 19e2a407 | 全局 pattern 0 种子 |

已有附加回归：

```text
python RTL/cluster/cluster_tb/py/run_regression.py --en a5 --oc 84218421 --depth 3 --full-act --mixed-context --latency-audit --log regression_act_frame_sparse_depth3.log
```

该回归检查稀疏 Macro/OC 与非二次幂的 Context 深度；实际配置数和 case 数见日志。计数记录在 [默认日志](RTL/cluster/cluster_tb/log/regression_act_frame_default.log) 和 [稀疏配置日志](RTL/cluster/cluster_tb/log/regression_act_frame_sparse_depth3.log)。

- [split_cases.csv](RTL/cluster/cluster_tb/data/split_cases.csv)：suite 1 每个配置一行（precision、符号、split、EN、OC、slot、各组 K），默认 200 行；不逐行记录 pattern 与其他三类 suite。
- [external_inputs.csv](RTL/cluster/cluster_tb/data/external_inputs.csv)：396条标准外部输入事件，分别记录Command接受、地址、ACT采样及1024-bit数据；act_sample仅为日志标记，并非外部pin。
- [buffer_operations.csv](RTL/cluster/cluster_tb/data/buffer_operations.csv)：suite 2 的逐拍运算记录，默认回归 480 条，compute_cycle 字段为相对首个输入的运算写回拍号、精度、Tile/Context/phase、操作类型、tmp、fusion/acc 操作数、结果与完成标志。
- [latency_audit.csv](RTL/cluster/cluster_tb/data/latency_audit.csv)：独立观察器记录的 140 个标准 Context 输出周期；[核对报告](RTL/cluster/cluster_tb/log/latency_audit_validation.log) 按六种配置公式逐条核对输入到输出周期。

`--gate-unit` 另外运行 [tb_ClusterReduceTree.sv](RTL/cluster/cluster_tb/sv_code/tb_ClusterReduceTree.sv)，不计入上述 1368 个 Cluster case。8 种 EN（FF、0F、F0、55、AA、81、01、00）×26 种规范 split=208 个 case，OC 按 case 序号轮换 FFFFFFFF、84218421、12345678；检查三级终点的数据与有效 mask、t1..t6 转发 DFF 的门控与保持、下游加法器被门控时的数据保持。这是独立归约树单测，不应用 Cluster 的 K<256 精度限制。

### 完整 ACT 与混合 Context

`--full-act` 额外运行12个 W8A16 定向case：两种符号×os=1/2×单Context/WS2/AS2。EN=FF、split=00、slots=[0,1,2,3,4,5,6,7]，使用完整256个ACT digit、四个1024-bit Plane和八个Macro root归约（K=256），检查全部4096-bit ACT存储及分发。此定向suite独立于默认K<256穷举。

### 混合 Context 与本地仿真副本

`--mixed-context` 在默认 suite 前额外运行24个定向 case：W4A4/A8/A16×两种符号×os=1/2×WS/AS双 Context。split=03、EN=55、slots=24'h040000、OC全开，同一树中同时存在 pair 与 quad 终点，检查不同 Context 的 channel 同拍发布。内部 raw_context 按 lane 保存，仅用于验证；没有新增对外 Context pin。默认1368个 case 的编号和计数保持独立。

本地 ModelSim 使用仓库外的源码副本，默认在仓库同级 `cluster_tb_work/local_sim/<日志名>/` 下生成 sv_code、py、work、data、log 和 source_manifest.json。源文件指纹记录本次实际仿真的输入。`--sim-dir PATH` 可指定仓库外的独立目录；该副本及仿真工作文件不提交 Git。

SV 中的 FSDB 调用由 `CLUSTER_FSDB` 编译宏控制；VCS Makefile 开启该宏，ModelSim 入口不启用。`OUTPUT_BUFFER_DEPTH` 控制 Context 状态深度，与输出 ready/valid 反压无关；输出无需 ready，out_valid_o[l] 每个有效周期发布一个新结果。深度1支持单 Context；完整回归需要至少2。`--psum-depth` 是 `--depth` 的命令行别名，不是第二个硬件深度参数。

## 附录 A 逐拍输入与运算

C0 是首个外部 i_cmd+A0 的接受沿。每例先列外部接受事件，再列内部发射与运算。内部表的ACT来自act_buffer，地址来自已接收descriptor；内部发射不要求外部cmd_fire。所有C周期使用同一实际时钟起点；tmp 在该写回周期前一拍捕获，状态写回 ICG 使能在 tmp 捕获时寄存；tmp 输入 ICG 使能则提前 tmp 捕获一拍寄存。

操作中的 R 是对应行输入的原始归约 slice；tmp 每 OC 唯一，P[c] 的索引为 Context 深度。WS 填充/fusion 在所列完成周期前一拍写 tmp，AS 的 fusion 与 acc 在所列周期写 Psum，“输出”表示该 Context raw 就绪。signed_en=0/1 共用时序。
"""


def main():
    lines = [BODY.rstrip()]
    for case, counts in enumerate(COUNTS, 1):
        os, ws, ac = counts
        mode = 'AS' if ac > 1 else 'WS' if ws > 1 else '单 Context'
        lines += ['', f'### A{case} {mode} os={os} ws={ws} as={ac}',
                  f'每 Tile K=128；每 Context 总 K={os*128}。']
        for p, name in enumerate(NAMES):
            split, en = ('07','55') if p < 2 else ('01','33') if p < 5 else ('00','0F')
            lines += ['', f'#### precision={p} {name}',
                      f"split_mask=7'h{split}，EN=8'h{en}，OC_MASK=32'hFFFF_FFFF；D={STANDARD_DELAY[p]}T。",
                      '']
            lines += ['外部输入：', '', '| 外部周期 | i_cmd 与共享权重地址 | ACT |', '|---|---|---|']
            for e in external_rows(p,counts):
                cmd = f"Ctx{e['context']}，wgt_raddr=8'h{e['address']:02X}" if e['command'] else '—'
                act = f"A{e['phase']}(T{e['tile']})" if e['phase'] is not None else '—'
                lines.append(f"| C{e['cycle']} | {cmd} | {act} |")
            lines += ['', '内部发射与运算：', '', '| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |', '|---|---|---|---|---|']
            seq = sequence(p, counts)
            last_addr = None
            for r in standard_rows(p, case):
                q,k,c,ph = (r[x] for x in ('issue','tile','context','phase'))
                address = 0x20+16*k+(c if ac>1 else 0)
                address_text = f"8'h{address:02X}" + ('（不变）' if address == last_addr else '')
                last_addr = address
                act = f'读 A{ph}(T{k})，Ctx{c}复用' if ac>1 else f'读 A{ph}(T{k},Ctx{c})'
                lines.append(f'| C{q} | {address_text} | {act} | C{r["compute"]} | {r["description"]} → {r["destination"]} |')
            out=[]
            for c in range(max(ws,ac)):
                q=max(issue_cycle(p,counts,k,cx,ph) for k,cx,ph in seq if cx==c)
                out.append(f'Ctx{c}：末内部发射 C{q}，raw 完成 C{q+STANDARD_DELAY[p]}')
            lines += ['', '；'.join(out)+'。']
    lines += ['', '## 附录 B 规范 split 编码', '',
              '以下按 bit6..bit0 给出26种规范编码，K 限制还需结合 precision、EN 和 OC：', '']
    masks=[]
    for mask in range(128):
        if not (mask&1) and mask: continue
        if not (mask&2) and (mask&0x18): continue
        if not (mask&4) and (mask&0x60): continue
        masks.append(mask)
    assert len(masks)==26
    lines.append('、'.join(f'`{x:07b}`' for x in masks))
    content='\n'.join(lines)+'\n'
    (REPO/'README.md').write_text(content,encoding='utf-8')
    print('Generated current-semantics README with 42 explicit input/operation tables')


if __name__ == '__main__':
    main()
