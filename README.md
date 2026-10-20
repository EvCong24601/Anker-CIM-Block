# CIM Cluster 输入与计算说明

本仓库包含八个 SingleMacro 组成的 Cluster 仿真参考实现。每条 Command 触发一个 ACT 4-bit slice 的计算；归约结果先进入 tmp，再进行 bit fusion 或 Psum acc。各 Context 独立输出 raw signed32，未包含 requant。

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
python RTL/cluster/cluster_tb/py/run_regression.py --gate-unit --latency-audit --log regression_tmp_default.log
```

ModelSim 的 vlib/vlog/vsim 需在 PATH 中。脚本从任意工作目录调用均可，CSV 固定写入 data，日志写入 log。VCS 入口位于 vcs-rtl；测试参数及其他运行方法见 [cluster_tb README](RTL/cluster/cluster_tb/README.md)。

## Cluster 接口

方向以 Cluster 为视角。

| 信号 | 方向与位宽 | 语义 |
|---|---|---|
| clock / reset | 输入，各 1 bit | 上升沿时钟，高有效异步复位 |
| cmd_i | 输入，131 bit | 每个 phase 的完整 descriptor |
| cmd_valid_i / cmd_ready_o | 输入 / 输出，各 1 bit | Command 接受握手 |
| act_data_i | 输入，1024 bit | 一个 Plane，含 256 个 4-bit digit；随 Command 接受沿采样 |
| weight_wen_i | 输入，8 bit | 预加载时选择写入的 Macro |
| weight_waddr_i | 输入，8 bit | 预加载行号 |
| weight_wdata_i | 输入，8192 bit | 八个 Macro 各一条 1024-bit 权重行 |
| psum_data_o | 输出，1024 bit | 32 个 channel 的 raw signed32 结果 |
| psum_lane_valid_o | 输出，32 bit | raw 向量内各 channel 的有效位 |
| out_valid_o / out_ready_i | 输出 / 输入，各 1 bit | 完整 raw 向量的消费握手 |

ACT 没有独立握手信号。`cmd_fire=cmd_valid_i&&cmd_ready_o` 同时是计算发射事件。

- WS/单 Context：每次 cmd_fire 采样 act_data_i。
- AS：每个 phase 的 Ctx0 在 cmd_fire 采样新 Plane；后续 Context 使用内部保存的数据，外部 ACT 不参与这些复用拍的计算。
- 需要采样新 ACT 而 Command 尚未被接受时，保持 Command 和 ACT 数据。没有 cmd_fire 时不推进 phase、Context 或 Tile。
- C0 可同时提供首条 Command、首个 ACT slice 和共享权重地址，不需要单独的配置加载周期。

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

`ws>1,as=1` 为 WS；`as>1,ws=1` 为 AS；`ws=as=1` 为单 Context。不支持 ws/as 同时大于 1。一个批次内 precision、符号、counts、split、mask、slot 固定，地址按每条 Command 采样。

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

| 归约终点 | Macro 发射 | tmp 捕获 | fusion/acc 写回或完成 |
|---|---|---|---|
| 叶子 / pair | Cq | C(q+2) | C(q+3) |
| quad | Cq | C(q+3) | C(q+4) |
| root | Cq | C(q+4) | C(q+5) |

标准 W2/W4/W8 的末输入到 raw 完成为 3T/4T/5T。混合树各 channel 按自身终点到达，整个 Context 的有效 channel 写齐后发布 raw 向量。上述延迟不含 Command 停顿、输出排队或下游等待。

## tmp bit fusion 与 Psum acc

每个并行 channel 共用一套 fusion 和 acc 组合块，Context 按 buffer 深度从低到高存放。令 R 为 tmp_result 中本拍归约结果，T[d] 为 tmp 的融合状态，P[d] 为 Psum 状态。

- os=1：A0 填充 T，后续 slice 执行 `T+(R<<(4*phase))`；最后 phase 直接输出。A4 从 tmp_result 直接输出，Psum 全部关闭。
- os>1、WS/单 Context：在 T[0] 融合当前 Tile。最后 phase 将首 Tile 的融合值写入 P[ctx]；后续 Tile 则执行 `P[ctx]+融合值` 并回写。
- os>1、AS：首 Tile/A0 将 R 写入 P[ctx]；后续 Tile/A0 执行 `P[ctx]+R`；A1..A3 执行 `P[ctx]+(R<<(4*phase))`。每次回写同一 Context，最后 Tile 的最后 phase 产生输出。

AS 每拍只选择 fusion 或 acc。WS/单 Context 在 A8/A16 的后续 Tile 最后 phase 可经过 fusion 加法器→acc 加法器串联路径，需要 STA 确认一拍时序。未使用组合块的两个输入均隔离为零。

AS 的相邻 slice 间隔为 n 个有效发射周期，n=as_cnt；相邻 Tile 间隔为 n×P，P=A位宽/4。OC 并行计算，不乘 OC 数。

## Buffer 深度与 ICG

`PSUM_BUFFER_DEPTH` 默认16，设置每 channel 的 Context 状态容量；`OUTPUT_BUFFER_DEPTH` 默认4，设置每 channel 最终输出 FIFO 容量。Context 数不超过状态容量。最终输出采用整向量 ready/valid 反压。

首条 Command 接受时锁定本批深度开放掩码，保持至最后 Context 的 raw 向量发布：os>1 仅开放 Psum 深度 `0..max(ws,as)-1`，其余高地址 entry 关闭；os=1 全部关闭。

tmp_input_cg_en 提前 tmp 捕获一拍寄存；tmp_state_cg_en/psum_cg_en 在 tmp 捕获时寄存，供下一拍写回。每深度/每 channel 的 DFF 接专用 ICG 模型。A4 的 T 状态 DFF 全关；A8/A16 的 WS/单 Context 仅开放 T[0]，os=1 的 AS 开放低 as 个 T 深度，os>1 的 AS 使用 P 保存融合历史。

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

WS/单 Context 顺序为 Tile→Context→phase；AS 为 Tile→phase→Context。令 R=max(ws,as)、P=A位宽/4、N=os×R×P，连续输入的最后一拍为 C(N−1)，整批 raw 完成为 C(N−1+D)。

默认回归为1368个 Cluster case，另有208个归约门控 case；检查140个 Context 输出周期和480个标准运算事件。EN=FF 时每符号在七种 precision 下的合法 split 数为1、1、16、16、16、25、25，要求每组有效 K<256。

验证包含 Command 停顿、输出反压、AS 外部 ACT 变化时内部 Plane 的复用、ICG 时钟、关闭 DFF 保持和高地址深度关闭。实现为仿真参考 adapter，未进行综合/STA/门级功耗验证，未包含 requant。

## tb_Cluster 测试 case

测试入口为 [tb_Cluster.sv](RTL/cluster/cluster_tb/sv_code/tb_Cluster.sv)。一个 case 指调用一次 `run_case`：先预加载本次使用的权重行，再发送完整的 Tile/Context/slice 序列，最后检查所有 Context 的 raw 结果和输出 FIFO 读出。一次 case 可包含多条 Command 和多个 Context 输出。

### 默认参数与 case 数

默认 `EN_MASK=8'hFF`、`OC_MASK=32'hFFFF_FFFF`、`OS_TILES=1`、`PATTERNS=6`、`OUTPUT_BUFFER_DEPTH=4`、`PSUM_BUFFER_DEPTH=16`、`SEED=32'h19E2_A407`。七种精度均测试 UINT×UINT 和 INT×INT；不包含混合符号乘法。

默认运行以下四类，共 **1368 个 Cluster case**：

1. **split 穷举：1200 个。** 从 7-bit split_mask 的 128 个值中选出 26 种规范树，再按每个归约组的 `K=有效 Macro 数×(256/W)<256` 筛选。每个合法 split 分别运行两种符号和六种数据 pattern；使用 `(os,ws,as)=(OS_TILES,1,1)`。组内有效 Macro 按编号分配不重叠 slot，编号从 0 开始。
2. **六种标准配置：84 个。** 七种精度×两种符号×六种配置，每次使用随机 pattern 0。六种配置依次为 `(1,1,1)`、`(1,1,2)`、`(1,2,1)`、`(2,1,1)`、`(2,2,1)`、`(2,1,2)`，对应附录 A1..A6。每 Tile K=128，采用上文 W2/W4/W8 标准 split、EN 和 slot，OC 全开。默认连续发射，用于检查无停顿逐拍时序。
3. **Command 空拍与输出反压：28 个。** 七种精度×两种符号×WS/AS。使用随机 pattern 0、`os=2`，Context 数 `r=min(OUTPUT_BUFFER_DEPTH+2,16,PSUM_BUFFER_DEPTH)`，默认 r=6；WS 为 `(2,r,1)`，AS 为 `(2,1,r)`。第 index 条输入前插入 `index%3` 个空拍；下游先保持不 ready，随后每四拍停一拍。默认 Context 数超过 FIFO 深度，检查写满、发射停顿、指针回绕及恢复后的结果顺序。
4. **三 Tile 极值与历史保持：56 个。** 七种精度×两种符号×WS/AS×pattern 4/5。使用 `os=3`，Context 数 `r=min(3,PSUM_BUFFER_DEPTH)`，默认 r=3；WS 为 `(3,r,1)`，AS 为 `(3,1,r)`。同时插入 Command 空拍和输出反压，检查多 Tile、多 Context 交错后 fusion/acc 历史未被覆盖。

EN=FF 时，七种精度的 split 穷举数量如下；“两种符号的 case 数”已包含六种 pattern，不包含后三类测试：

- precision 0 / W2A4：每种符号 1 个 split，两种符号共 12 个 case。
- precision 1 / W2A8：每种符号 1 个 split，两种符号共 12 个 case。
- precision 2 / W4A4：每种符号 16 个 split，两种符号共 192 个 case。
- precision 3 / W4A8：每种符号 16 个 split，两种符号共 192 个 case。
- precision 4 / W4A16：每种符号 16 个 split，两种符号共 192 个 case。
- precision 5 / W8A8：每种符号 25 个 split，两种符号共 300 个 case。
- precision 6 / W8A16：每种符号 25 个 split，两种符号共 300 个 case。

合法 split×符号共 200 个配置，故默认总数为 `200×6+84+28+56=1368`。`data/buffer_cycle_cases.csv` 中的 1200 个组合是这 200 个配置再展开六种 WS/AS/OS 调度后的逻辑时序清单，与上面的 1200 个数据 pattern 仿真 case 含义不同。

### 六种输入数据 pattern

pattern 同时用于产生 ACT 和 weight，按各自精度取值。令 INT 的 hi 为最大正数、lo 为最小负数；UINT 的 hi 为全 1、lo 为 0：

- `0`：xorshift 伪随机位模式，由 SEED 决定；split 穷举的这一项插入 Command 空拍。
- `1`：ACT 和 weight 全零。
- `2`：ACT 和 weight 均取 hi。
- `3`：ACT 和 weight 均取 lo。
- `4`：各自按元素 index 在 lo/hi 间交替，偶数取 lo、奇数取 hi。
- `5`：ACT 与 pattern 4 相同；weight 改为偶数取 hi、奇数取 lo。这里的 index 是数据生成函数的元素索引，不是输入周期。

UINT W8A16 的 ACT 另外取模 `32768/os`，以使最终结果落在 raw signed32 范围内；这部分测试不覆盖完整 UINT16 数值范围。最终溢出会直接报错，没有 requant 或饱和处理。

### 每个 case 检查什么

- **数值与有效通道：** 使用完整 ACT/weight 整数计算独立点积，逐 channel 比较 raw 和 FIFO 读出结果，检查 OC mask、Context 顺序及输出无丢失、重复。
- **发射与输入：** 检查 WS 的 Tile→Context→phase、AS 的 Tile→phase→Context 顺序，以及共享权重地址。WS/单 Context 地址为 `8'h20+16*Tile`；AS 另加 Context 编号。AS 复用拍故意向外部 ACT 驱动相反位模式，确认 DUT 仍使用已保存的 Plane；Command 被阻塞时检查所需 Command/ACT 保持稳定。
- **流水与 buffer 历史：** 逐 channel 检查归约终点对应的 3T/4T/5T 写回，混合树检查各通道分别到达；逐 phase 检查 WS tmp、AS Psum 的中间值，以及 os=1 不写 Psum。检查 WS 最后 phase 的 fusion+acc 和 AS 单拍 fusion/acc 二选一路径。
- **时钟门控与反压：** 检查提前产生的 ICG 使能、实际门控时钟、关闭 DFF 的数据保持、高地址 Context entry 整批关闭、未用加法器的两个输入为零，以及输出反压时 data/valid/mask 稳定。结束时检查 FIFO 排空和所需路径覆盖计数。

### 运行、参数作用范围与结果

从仓库根目录运行默认回归、归约门控单测和独立时延核对：

```text
python RTL/cluster/cluster_tb/py/run_regression.py --gate-unit --latency-audit --log regression_tmp_default.log
```

`--en`、`--oc`、`--os`、`--patterns` 只改变第一类 split 穷举 suite；其余三类仍使用标准 K128 映射、OC 全开及各自规定的 counts/pattern。改变 EN 会重新筛选合法 split；K 筛选按 EN 计算，不因关闭 OC 而放宽。`--patterns N` 选用前 N 种 pattern，因此不会关闭第四类固定使用的 pattern 4/5。`--depth`、`--psum-depth` 和 `--seed` 作用于整个 Cluster 回归。Python 入口要求 psum-depth 为 2..16；深度不足三 Context 时第四类按可用深度运行。输出深度为 1 时标准配置也会施加反压，独立无停顿时延核对要求输出深度至少 2。

已有附加回归：

```text
python RTL/cluster/cluster_tb/py/run_regression.py --depth 1 --psum-depth 3 --patterns 2 --log regression_tmp_depth1.log
python RTL/cluster/cluster_tb/py/run_regression.py --en 81 --oc 84218421 --os 2 --depth 3 --psum-depth 3 --patterns 2 --log regression_tmp_sparse_depth3.log
```

前者为 568 个 case，检查单 entry FIFO；后者为 888 个 case，其中 split×符号配置 360 个，检查稀疏 Macro/OC 和非二次幂深度 FIFO。这些计数分别记录在 [默认日志](RTL/cluster/cluster_tb/log/regression_tmp_default.log)、[深度 1 日志](RTL/cluster/cluster_tb/log/regression_tmp_depth1.log) 和 [稀疏配置日志](RTL/cluster/cluster_tb/log/regression_tmp_sparse_depth3.log)。

- [split_cases.csv](RTL/cluster/cluster_tb/data/split_cases.csv)：第一类测试的 precision、符号、split、EN、OC、slot 和各组 K；不逐行记录六种 pattern 或其他三类测试。
- [buffer_operations.csv](RTL/cluster/cluster_tb/data/buffer_operations.csv)：六种标准配置的实际运算记录，无停顿回归共 480 条，每拍选取一个有效 channel 记录操作数、结果与完成标志。
- [latency_audit.csv](RTL/cluster/cluster_tb/data/latency_audit.csv)：独立观察器记录的 140 个标准 Context 输出；[核对报告](RTL/cluster/cluster_tb/log/latency_audit_validation.log) 检查输入到输出周期。

`--gate-unit` 另外运行 [tb_ClusterReduceTree.sv](RTL/cluster/cluster_tb/sv_code/tb_ClusterReduceTree.sv)，不计入上述 1368 个 Cluster case。它以八种 EN（FF、0F、F0、55、AA、81、01、00）分别遍历 26 种规范 split，共 208 个 case，OC 按 case 轮换 FFFFFFFF、84218421、12345678；检查各级终点数据、有效 mask、t1..t6 转发 DFF 的门控和保持。这是独立归约树单测，不应用 Cluster 的 K<256 精度限制。

## 附录 A 逐拍输入与运算

C0 是首个 Command 的接受沿。每行均有 cmd_fire=1，地址属于该条 descriptor。ACT 列的“采样”表示该沿读取 act_data_i；“复用”表示不采样外部 ACT。写回周期采用实际输入起点；tmp 在该写回周期前一拍捕获，状态写回 ICG 使能在 tmp 捕获时寄存；tmp 输入 ICG 使能则提前 tmp 捕获一拍寄存。

操作中的 R 是对应行输入计算得到的归约值；T/P 的索引为 Context 状态深度，“输出”表示该 Context raw 就绪。signed_en=0/1 共用时序。

### A1 单 Context os=1 ws=1 as=1
每 Tile K=128；每 Context 总 K=128。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C3 | 填充: R → 直接输出 |

Ctx0：末输入 C0，raw 完成 C3。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C3 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C4 | fusion: T[0] + (R << 4) → T[0]；输出 |

Ctx0：末输入 C1，raw 完成 C4。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C4 | 填充: R → 直接输出 |

Ctx0：末输入 C0，raw 完成 C4。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C4 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C5 | fusion: T[0] + (R << 4) → T[0]；输出 |

Ctx0：末输入 C1，raw 完成 C5。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C4 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C5 | fusion: T[0] + (R << 4) → T[0] |
| C2 | 8'h20（不变） | 采样 A2(T0,Ctx0) | C6 | fusion: T[0] + (R << 8) → T[0] |
| C3 | 8'h20（不变） | 采样 A3(T0,Ctx0) | C7 | fusion: T[0] + (R << 12) → T[0]；输出 |

Ctx0：末输入 C3，raw 完成 C7。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C5 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C6 | fusion: T[0] + (R << 4) → T[0]；输出 |

Ctx0：末输入 C1，raw 完成 C6。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C5 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C6 | fusion: T[0] + (R << 4) → T[0] |
| C2 | 8'h20（不变） | 采样 A2(T0,Ctx0) | C7 | fusion: T[0] + (R << 8) → T[0] |
| C3 | 8'h20（不变） | 采样 A3(T0,Ctx0) | C8 | fusion: T[0] + (R << 12) → T[0]；输出 |

Ctx0：末输入 C3，raw 完成 C8。

### A2 AS os=1 ws=1 as=2
每 Tile K=128；每 Context 总 K=128。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0) | C3 | 填充: R → 直接输出 |
| C1 | 8'h21 | 复用 A0(T0) | C4 | 填充: R → 直接输出 |

Ctx0：末输入 C0，raw 完成 C3；Ctx1：末输入 C1，raw 完成 C4。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0) | C3 | 填充: R → T[0] |
| C1 | 8'h21 | 复用 A0(T0) | C4 | 填充: R → T[1] |
| C2 | 8'h20 | 采样 A1(T0) | C5 | fusion: T[0] + (R << 4) → T[0]；输出 |
| C3 | 8'h21 | 复用 A1(T0) | C6 | fusion: T[1] + (R << 4) → T[1]；输出 |

Ctx0：末输入 C2，raw 完成 C5；Ctx1：末输入 C3，raw 完成 C6。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0) | C4 | 填充: R → 直接输出 |
| C1 | 8'h21 | 复用 A0(T0) | C5 | 填充: R → 直接输出 |

Ctx0：末输入 C0，raw 完成 C4；Ctx1：末输入 C1，raw 完成 C5。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0) | C4 | 填充: R → T[0] |
| C1 | 8'h21 | 复用 A0(T0) | C5 | 填充: R → T[1] |
| C2 | 8'h20 | 采样 A1(T0) | C6 | fusion: T[0] + (R << 4) → T[0]；输出 |
| C3 | 8'h21 | 复用 A1(T0) | C7 | fusion: T[1] + (R << 4) → T[1]；输出 |

Ctx0：末输入 C2，raw 完成 C6；Ctx1：末输入 C3，raw 完成 C7。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0) | C4 | 填充: R → T[0] |
| C1 | 8'h21 | 复用 A0(T0) | C5 | 填充: R → T[1] |
| C2 | 8'h20 | 采样 A1(T0) | C6 | fusion: T[0] + (R << 4) → T[0] |
| C3 | 8'h21 | 复用 A1(T0) | C7 | fusion: T[1] + (R << 4) → T[1] |
| C4 | 8'h20 | 采样 A2(T0) | C8 | fusion: T[0] + (R << 8) → T[0] |
| C5 | 8'h21 | 复用 A2(T0) | C9 | fusion: T[1] + (R << 8) → T[1] |
| C6 | 8'h20 | 采样 A3(T0) | C10 | fusion: T[0] + (R << 12) → T[0]；输出 |
| C7 | 8'h21 | 复用 A3(T0) | C11 | fusion: T[1] + (R << 12) → T[1]；输出 |

Ctx0：末输入 C6，raw 完成 C10；Ctx1：末输入 C7，raw 完成 C11。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0) | C5 | 填充: R → T[0] |
| C1 | 8'h21 | 复用 A0(T0) | C6 | 填充: R → T[1] |
| C2 | 8'h20 | 采样 A1(T0) | C7 | fusion: T[0] + (R << 4) → T[0]；输出 |
| C3 | 8'h21 | 复用 A1(T0) | C8 | fusion: T[1] + (R << 4) → T[1]；输出 |

Ctx0：末输入 C2，raw 完成 C7；Ctx1：末输入 C3，raw 完成 C8。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0) | C5 | 填充: R → T[0] |
| C1 | 8'h21 | 复用 A0(T0) | C6 | 填充: R → T[1] |
| C2 | 8'h20 | 采样 A1(T0) | C7 | fusion: T[0] + (R << 4) → T[0] |
| C3 | 8'h21 | 复用 A1(T0) | C8 | fusion: T[1] + (R << 4) → T[1] |
| C4 | 8'h20 | 采样 A2(T0) | C9 | fusion: T[0] + (R << 8) → T[0] |
| C5 | 8'h21 | 复用 A2(T0) | C10 | fusion: T[1] + (R << 8) → T[1] |
| C6 | 8'h20 | 采样 A3(T0) | C11 | fusion: T[0] + (R << 12) → T[0]；输出 |
| C7 | 8'h21 | 复用 A3(T0) | C12 | fusion: T[1] + (R << 12) → T[1]；输出 |

Ctx0：末输入 C6，raw 完成 C11；Ctx1：末输入 C7，raw 完成 C12。

### A3 WS os=1 ws=2 as=1
每 Tile K=128；每 Context 总 K=128。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C3 | 填充: R → 直接输出 |
| C1 | 8'h20（不变） | 采样 A0(T0,Ctx1) | C4 | 填充: R → 直接输出 |

Ctx0：末输入 C0，raw 完成 C3；Ctx1：末输入 C1，raw 完成 C4。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C3 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C4 | fusion: T[0] + (R << 4) → T[0]；输出 |
| C2 | 8'h20（不变） | 采样 A0(T0,Ctx1) | C5 | 填充: R → T[0] |
| C3 | 8'h20（不变） | 采样 A1(T0,Ctx1) | C6 | fusion: T[0] + (R << 4) → T[0]；输出 |

Ctx0：末输入 C1，raw 完成 C4；Ctx1：末输入 C3，raw 完成 C6。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C4 | 填充: R → 直接输出 |
| C1 | 8'h20（不变） | 采样 A0(T0,Ctx1) | C5 | 填充: R → 直接输出 |

Ctx0：末输入 C0，raw 完成 C4；Ctx1：末输入 C1，raw 完成 C5。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C4 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C5 | fusion: T[0] + (R << 4) → T[0]；输出 |
| C2 | 8'h20（不变） | 采样 A0(T0,Ctx1) | C6 | 填充: R → T[0] |
| C3 | 8'h20（不变） | 采样 A1(T0,Ctx1) | C7 | fusion: T[0] + (R << 4) → T[0]；输出 |

Ctx0：末输入 C1，raw 完成 C5；Ctx1：末输入 C3，raw 完成 C7。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C4 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C5 | fusion: T[0] + (R << 4) → T[0] |
| C2 | 8'h20（不变） | 采样 A2(T0,Ctx0) | C6 | fusion: T[0] + (R << 8) → T[0] |
| C3 | 8'h20（不变） | 采样 A3(T0,Ctx0) | C7 | fusion: T[0] + (R << 12) → T[0]；输出 |
| C4 | 8'h20（不变） | 采样 A0(T0,Ctx1) | C8 | 填充: R → T[0] |
| C5 | 8'h20（不变） | 采样 A1(T0,Ctx1) | C9 | fusion: T[0] + (R << 4) → T[0] |
| C6 | 8'h20（不变） | 采样 A2(T0,Ctx1) | C10 | fusion: T[0] + (R << 8) → T[0] |
| C7 | 8'h20（不变） | 采样 A3(T0,Ctx1) | C11 | fusion: T[0] + (R << 12) → T[0]；输出 |

Ctx0：末输入 C3，raw 完成 C7；Ctx1：末输入 C7，raw 完成 C11。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C5 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C6 | fusion: T[0] + (R << 4) → T[0]；输出 |
| C2 | 8'h20（不变） | 采样 A0(T0,Ctx1) | C7 | 填充: R → T[0] |
| C3 | 8'h20（不变） | 采样 A1(T0,Ctx1) | C8 | fusion: T[0] + (R << 4) → T[0]；输出 |

Ctx0：末输入 C1，raw 完成 C6；Ctx1：末输入 C3，raw 完成 C8。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C5 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C6 | fusion: T[0] + (R << 4) → T[0] |
| C2 | 8'h20（不变） | 采样 A2(T0,Ctx0) | C7 | fusion: T[0] + (R << 8) → T[0] |
| C3 | 8'h20（不变） | 采样 A3(T0,Ctx0) | C8 | fusion: T[0] + (R << 12) → T[0]；输出 |
| C4 | 8'h20（不变） | 采样 A0(T0,Ctx1) | C9 | 填充: R → T[0] |
| C5 | 8'h20（不变） | 采样 A1(T0,Ctx1) | C10 | fusion: T[0] + (R << 4) → T[0] |
| C6 | 8'h20（不变） | 采样 A2(T0,Ctx1) | C11 | fusion: T[0] + (R << 8) → T[0] |
| C7 | 8'h20（不变） | 采样 A3(T0,Ctx1) | C12 | fusion: T[0] + (R << 12) → T[0]；输出 |

Ctx0：末输入 C3，raw 完成 C8；Ctx1：末输入 C7，raw 完成 C12。

### A4 单 Context os=2 ws=1 as=1
每 Tile K=128；每 Context 总 K=256。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C3 | 初次填充: R → P[0] |
| C1 | 8'h30 | 采样 A0(T1,Ctx0) | C4 | acc: P[0] + R → P[0]；输出 |

Ctx0：末输入 C1，raw 完成 C4。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C3 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C4 | fusion: T[0] + (R << 4)；融合值填充 Psum → T[0]；P[0] |
| C2 | 8'h30 | 采样 A0(T1,Ctx0) | C5 | 填充: R → T[0] |
| C3 | 8'h30（不变） | 采样 A1(T1,Ctx0) | C6 | fusion: T[0] + (R << 4) → F；acc: P[0] + F → T[0]；P[0]；输出 |

Ctx0：末输入 C3，raw 完成 C6。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C4 | 初次填充: R → P[0] |
| C1 | 8'h30 | 采样 A0(T1,Ctx0) | C5 | acc: P[0] + R → P[0]；输出 |

Ctx0：末输入 C1，raw 完成 C5。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C4 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C5 | fusion: T[0] + (R << 4)；融合值填充 Psum → T[0]；P[0] |
| C2 | 8'h30 | 采样 A0(T1,Ctx0) | C6 | 填充: R → T[0] |
| C3 | 8'h30（不变） | 采样 A1(T1,Ctx0) | C7 | fusion: T[0] + (R << 4) → F；acc: P[0] + F → T[0]；P[0]；输出 |

Ctx0：末输入 C3，raw 完成 C7。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C4 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C5 | fusion: T[0] + (R << 4) → T[0] |
| C2 | 8'h20（不变） | 采样 A2(T0,Ctx0) | C6 | fusion: T[0] + (R << 8) → T[0] |
| C3 | 8'h20（不变） | 采样 A3(T0,Ctx0) | C7 | fusion: T[0] + (R << 12)；融合值填充 Psum → T[0]；P[0] |
| C4 | 8'h30 | 采样 A0(T1,Ctx0) | C8 | 填充: R → T[0] |
| C5 | 8'h30（不变） | 采样 A1(T1,Ctx0) | C9 | fusion: T[0] + (R << 4) → T[0] |
| C6 | 8'h30（不变） | 采样 A2(T1,Ctx0) | C10 | fusion: T[0] + (R << 8) → T[0] |
| C7 | 8'h30（不变） | 采样 A3(T1,Ctx0) | C11 | fusion: T[0] + (R << 12) → F；acc: P[0] + F → T[0]；P[0]；输出 |

Ctx0：末输入 C7，raw 完成 C11。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C5 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C6 | fusion: T[0] + (R << 4)；融合值填充 Psum → T[0]；P[0] |
| C2 | 8'h30 | 采样 A0(T1,Ctx0) | C7 | 填充: R → T[0] |
| C3 | 8'h30（不变） | 采样 A1(T1,Ctx0) | C8 | fusion: T[0] + (R << 4) → F；acc: P[0] + F → T[0]；P[0]；输出 |

Ctx0：末输入 C3，raw 完成 C8。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C5 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C6 | fusion: T[0] + (R << 4) → T[0] |
| C2 | 8'h20（不变） | 采样 A2(T0,Ctx0) | C7 | fusion: T[0] + (R << 8) → T[0] |
| C3 | 8'h20（不变） | 采样 A3(T0,Ctx0) | C8 | fusion: T[0] + (R << 12)；融合值填充 Psum → T[0]；P[0] |
| C4 | 8'h30 | 采样 A0(T1,Ctx0) | C9 | 填充: R → T[0] |
| C5 | 8'h30（不变） | 采样 A1(T1,Ctx0) | C10 | fusion: T[0] + (R << 4) → T[0] |
| C6 | 8'h30（不变） | 采样 A2(T1,Ctx0) | C11 | fusion: T[0] + (R << 8) → T[0] |
| C7 | 8'h30（不变） | 采样 A3(T1,Ctx0) | C12 | fusion: T[0] + (R << 12) → F；acc: P[0] + F → T[0]；P[0]；输出 |

Ctx0：末输入 C7，raw 完成 C12。

### A5 WS os=2 ws=2 as=1
每 Tile K=128；每 Context 总 K=256。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C3 | 初次填充: R → P[0] |
| C1 | 8'h20（不变） | 采样 A0(T0,Ctx1) | C4 | 初次填充: R → P[1] |
| C2 | 8'h30 | 采样 A0(T1,Ctx0) | C5 | acc: P[0] + R → P[0]；输出 |
| C3 | 8'h30（不变） | 采样 A0(T1,Ctx1) | C6 | acc: P[1] + R → P[1]；输出 |

Ctx0：末输入 C2，raw 完成 C5；Ctx1：末输入 C3，raw 完成 C6。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C3 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C4 | fusion: T[0] + (R << 4)；融合值填充 Psum → T[0]；P[0] |
| C2 | 8'h20（不变） | 采样 A0(T0,Ctx1) | C5 | 填充: R → T[0] |
| C3 | 8'h20（不变） | 采样 A1(T0,Ctx1) | C6 | fusion: T[0] + (R << 4)；融合值填充 Psum → T[0]；P[1] |
| C4 | 8'h30 | 采样 A0(T1,Ctx0) | C7 | 填充: R → T[0] |
| C5 | 8'h30（不变） | 采样 A1(T1,Ctx0) | C8 | fusion: T[0] + (R << 4) → F；acc: P[0] + F → T[0]；P[0]；输出 |
| C6 | 8'h30（不变） | 采样 A0(T1,Ctx1) | C9 | 填充: R → T[0] |
| C7 | 8'h30（不变） | 采样 A1(T1,Ctx1) | C10 | fusion: T[0] + (R << 4) → F；acc: P[1] + F → T[0]；P[1]；输出 |

Ctx0：末输入 C5，raw 完成 C8；Ctx1：末输入 C7，raw 完成 C10。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C4 | 初次填充: R → P[0] |
| C1 | 8'h20（不变） | 采样 A0(T0,Ctx1) | C5 | 初次填充: R → P[1] |
| C2 | 8'h30 | 采样 A0(T1,Ctx0) | C6 | acc: P[0] + R → P[0]；输出 |
| C3 | 8'h30（不变） | 采样 A0(T1,Ctx1) | C7 | acc: P[1] + R → P[1]；输出 |

Ctx0：末输入 C2，raw 完成 C6；Ctx1：末输入 C3，raw 完成 C7。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C4 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C5 | fusion: T[0] + (R << 4)；融合值填充 Psum → T[0]；P[0] |
| C2 | 8'h20（不变） | 采样 A0(T0,Ctx1) | C6 | 填充: R → T[0] |
| C3 | 8'h20（不变） | 采样 A1(T0,Ctx1) | C7 | fusion: T[0] + (R << 4)；融合值填充 Psum → T[0]；P[1] |
| C4 | 8'h30 | 采样 A0(T1,Ctx0) | C8 | 填充: R → T[0] |
| C5 | 8'h30（不变） | 采样 A1(T1,Ctx0) | C9 | fusion: T[0] + (R << 4) → F；acc: P[0] + F → T[0]；P[0]；输出 |
| C6 | 8'h30（不变） | 采样 A0(T1,Ctx1) | C10 | 填充: R → T[0] |
| C7 | 8'h30（不变） | 采样 A1(T1,Ctx1) | C11 | fusion: T[0] + (R << 4) → F；acc: P[1] + F → T[0]；P[1]；输出 |

Ctx0：末输入 C5，raw 完成 C9；Ctx1：末输入 C7，raw 完成 C11。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C4 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C5 | fusion: T[0] + (R << 4) → T[0] |
| C2 | 8'h20（不变） | 采样 A2(T0,Ctx0) | C6 | fusion: T[0] + (R << 8) → T[0] |
| C3 | 8'h20（不变） | 采样 A3(T0,Ctx0) | C7 | fusion: T[0] + (R << 12)；融合值填充 Psum → T[0]；P[0] |
| C4 | 8'h20（不变） | 采样 A0(T0,Ctx1) | C8 | 填充: R → T[0] |
| C5 | 8'h20（不变） | 采样 A1(T0,Ctx1) | C9 | fusion: T[0] + (R << 4) → T[0] |
| C6 | 8'h20（不变） | 采样 A2(T0,Ctx1) | C10 | fusion: T[0] + (R << 8) → T[0] |
| C7 | 8'h20（不变） | 采样 A3(T0,Ctx1) | C11 | fusion: T[0] + (R << 12)；融合值填充 Psum → T[0]；P[1] |
| C8 | 8'h30 | 采样 A0(T1,Ctx0) | C12 | 填充: R → T[0] |
| C9 | 8'h30（不变） | 采样 A1(T1,Ctx0) | C13 | fusion: T[0] + (R << 4) → T[0] |
| C10 | 8'h30（不变） | 采样 A2(T1,Ctx0) | C14 | fusion: T[0] + (R << 8) → T[0] |
| C11 | 8'h30（不变） | 采样 A3(T1,Ctx0) | C15 | fusion: T[0] + (R << 12) → F；acc: P[0] + F → T[0]；P[0]；输出 |
| C12 | 8'h30（不变） | 采样 A0(T1,Ctx1) | C16 | 填充: R → T[0] |
| C13 | 8'h30（不变） | 采样 A1(T1,Ctx1) | C17 | fusion: T[0] + (R << 4) → T[0] |
| C14 | 8'h30（不变） | 采样 A2(T1,Ctx1) | C18 | fusion: T[0] + (R << 8) → T[0] |
| C15 | 8'h30（不变） | 采样 A3(T1,Ctx1) | C19 | fusion: T[0] + (R << 12) → F；acc: P[1] + F → T[0]；P[1]；输出 |

Ctx0：末输入 C11，raw 完成 C15；Ctx1：末输入 C15，raw 完成 C19。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C5 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C6 | fusion: T[0] + (R << 4)；融合值填充 Psum → T[0]；P[0] |
| C2 | 8'h20（不变） | 采样 A0(T0,Ctx1) | C7 | 填充: R → T[0] |
| C3 | 8'h20（不变） | 采样 A1(T0,Ctx1) | C8 | fusion: T[0] + (R << 4)；融合值填充 Psum → T[0]；P[1] |
| C4 | 8'h30 | 采样 A0(T1,Ctx0) | C9 | 填充: R → T[0] |
| C5 | 8'h30（不变） | 采样 A1(T1,Ctx0) | C10 | fusion: T[0] + (R << 4) → F；acc: P[0] + F → T[0]；P[0]；输出 |
| C6 | 8'h30（不变） | 采样 A0(T1,Ctx1) | C11 | 填充: R → T[0] |
| C7 | 8'h30（不变） | 采样 A1(T1,Ctx1) | C12 | fusion: T[0] + (R << 4) → F；acc: P[1] + F → T[0]；P[1]；输出 |

Ctx0：末输入 C5，raw 完成 C10；Ctx1：末输入 C7，raw 完成 C12。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0,Ctx0) | C5 | 填充: R → T[0] |
| C1 | 8'h20（不变） | 采样 A1(T0,Ctx0) | C6 | fusion: T[0] + (R << 4) → T[0] |
| C2 | 8'h20（不变） | 采样 A2(T0,Ctx0) | C7 | fusion: T[0] + (R << 8) → T[0] |
| C3 | 8'h20（不变） | 采样 A3(T0,Ctx0) | C8 | fusion: T[0] + (R << 12)；融合值填充 Psum → T[0]；P[0] |
| C4 | 8'h20（不变） | 采样 A0(T0,Ctx1) | C9 | 填充: R → T[0] |
| C5 | 8'h20（不变） | 采样 A1(T0,Ctx1) | C10 | fusion: T[0] + (R << 4) → T[0] |
| C6 | 8'h20（不变） | 采样 A2(T0,Ctx1) | C11 | fusion: T[0] + (R << 8) → T[0] |
| C7 | 8'h20（不变） | 采样 A3(T0,Ctx1) | C12 | fusion: T[0] + (R << 12)；融合值填充 Psum → T[0]；P[1] |
| C8 | 8'h30 | 采样 A0(T1,Ctx0) | C13 | 填充: R → T[0] |
| C9 | 8'h30（不变） | 采样 A1(T1,Ctx0) | C14 | fusion: T[0] + (R << 4) → T[0] |
| C10 | 8'h30（不变） | 采样 A2(T1,Ctx0) | C15 | fusion: T[0] + (R << 8) → T[0] |
| C11 | 8'h30（不变） | 采样 A3(T1,Ctx0) | C16 | fusion: T[0] + (R << 12) → F；acc: P[0] + F → T[0]；P[0]；输出 |
| C12 | 8'h30（不变） | 采样 A0(T1,Ctx1) | C17 | 填充: R → T[0] |
| C13 | 8'h30（不变） | 采样 A1(T1,Ctx1) | C18 | fusion: T[0] + (R << 4) → T[0] |
| C14 | 8'h30（不变） | 采样 A2(T1,Ctx1) | C19 | fusion: T[0] + (R << 8) → T[0] |
| C15 | 8'h30（不变） | 采样 A3(T1,Ctx1) | C20 | fusion: T[0] + (R << 12) → F；acc: P[1] + F → T[0]；P[1]；输出 |

Ctx0：末输入 C11，raw 完成 C16；Ctx1：末输入 C15，raw 完成 C20。

### A6 AS os=2 ws=1 as=2
每 Tile K=128；每 Context 总 K=256。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0) | C3 | 初次填充: R → P[0] |
| C1 | 8'h21 | 复用 A0(T0) | C4 | 初次填充: R → P[1] |
| C2 | 8'h30 | 采样 A0(T1) | C5 | acc: P[0] + R → P[0]；输出 |
| C3 | 8'h31 | 复用 A0(T1) | C6 | acc: P[1] + R → P[1]；输出 |

Ctx0：末输入 C2，raw 完成 C5；Ctx1：末输入 C3，raw 完成 C6。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0) | C3 | 初次填充: R → P[0] |
| C1 | 8'h21 | 复用 A0(T0) | C4 | 初次填充: R → P[1] |
| C2 | 8'h20 | 采样 A1(T0) | C5 | fusion: P[0] + (R << 4) → P[0] |
| C3 | 8'h21 | 复用 A1(T0) | C6 | fusion: P[1] + (R << 4) → P[1] |
| C4 | 8'h30 | 采样 A0(T1) | C7 | acc: P[0] + R → P[0] |
| C5 | 8'h31 | 复用 A0(T1) | C8 | acc: P[1] + R → P[1] |
| C6 | 8'h30 | 采样 A1(T1) | C9 | fusion: P[0] + (R << 4) → P[0]；输出 |
| C7 | 8'h31 | 复用 A1(T1) | C10 | fusion: P[1] + (R << 4) → P[1]；输出 |

Ctx0：末输入 C6，raw 完成 C9；Ctx1：末输入 C7，raw 完成 C10。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0) | C4 | 初次填充: R → P[0] |
| C1 | 8'h21 | 复用 A0(T0) | C5 | 初次填充: R → P[1] |
| C2 | 8'h30 | 采样 A0(T1) | C6 | acc: P[0] + R → P[0]；输出 |
| C3 | 8'h31 | 复用 A0(T1) | C7 | acc: P[1] + R → P[1]；输出 |

Ctx0：末输入 C2，raw 完成 C6；Ctx1：末输入 C3，raw 完成 C7。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0) | C4 | 初次填充: R → P[0] |
| C1 | 8'h21 | 复用 A0(T0) | C5 | 初次填充: R → P[1] |
| C2 | 8'h20 | 采样 A1(T0) | C6 | fusion: P[0] + (R << 4) → P[0] |
| C3 | 8'h21 | 复用 A1(T0) | C7 | fusion: P[1] + (R << 4) → P[1] |
| C4 | 8'h30 | 采样 A0(T1) | C8 | acc: P[0] + R → P[0] |
| C5 | 8'h31 | 复用 A0(T1) | C9 | acc: P[1] + R → P[1] |
| C6 | 8'h30 | 采样 A1(T1) | C10 | fusion: P[0] + (R << 4) → P[0]；输出 |
| C7 | 8'h31 | 复用 A1(T1) | C11 | fusion: P[1] + (R << 4) → P[1]；输出 |

Ctx0：末输入 C6，raw 完成 C10；Ctx1：末输入 C7，raw 完成 C11。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0) | C4 | 初次填充: R → P[0] |
| C1 | 8'h21 | 复用 A0(T0) | C5 | 初次填充: R → P[1] |
| C2 | 8'h20 | 采样 A1(T0) | C6 | fusion: P[0] + (R << 4) → P[0] |
| C3 | 8'h21 | 复用 A1(T0) | C7 | fusion: P[1] + (R << 4) → P[1] |
| C4 | 8'h20 | 采样 A2(T0) | C8 | fusion: P[0] + (R << 8) → P[0] |
| C5 | 8'h21 | 复用 A2(T0) | C9 | fusion: P[1] + (R << 8) → P[1] |
| C6 | 8'h20 | 采样 A3(T0) | C10 | fusion: P[0] + (R << 12) → P[0] |
| C7 | 8'h21 | 复用 A3(T0) | C11 | fusion: P[1] + (R << 12) → P[1] |
| C8 | 8'h30 | 采样 A0(T1) | C12 | acc: P[0] + R → P[0] |
| C9 | 8'h31 | 复用 A0(T1) | C13 | acc: P[1] + R → P[1] |
| C10 | 8'h30 | 采样 A1(T1) | C14 | fusion: P[0] + (R << 4) → P[0] |
| C11 | 8'h31 | 复用 A1(T1) | C15 | fusion: P[1] + (R << 4) → P[1] |
| C12 | 8'h30 | 采样 A2(T1) | C16 | fusion: P[0] + (R << 8) → P[0] |
| C13 | 8'h31 | 复用 A2(T1) | C17 | fusion: P[1] + (R << 8) → P[1] |
| C14 | 8'h30 | 采样 A3(T1) | C18 | fusion: P[0] + (R << 12) → P[0]；输出 |
| C15 | 8'h31 | 复用 A3(T1) | C19 | fusion: P[1] + (R << 12) → P[1]；输出 |

Ctx0：末输入 C14，raw 完成 C18；Ctx1：末输入 C15，raw 完成 C19。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0) | C5 | 初次填充: R → P[0] |
| C1 | 8'h21 | 复用 A0(T0) | C6 | 初次填充: R → P[1] |
| C2 | 8'h20 | 采样 A1(T0) | C7 | fusion: P[0] + (R << 4) → P[0] |
| C3 | 8'h21 | 复用 A1(T0) | C8 | fusion: P[1] + (R << 4) → P[1] |
| C4 | 8'h30 | 采样 A0(T1) | C9 | acc: P[0] + R → P[0] |
| C5 | 8'h31 | 复用 A0(T1) | C10 | acc: P[1] + R → P[1] |
| C6 | 8'h30 | 采样 A1(T1) | C11 | fusion: P[0] + (R << 4) → P[0]；输出 |
| C7 | 8'h31 | 复用 A1(T1) | C12 | fusion: P[1] + (R << 4) → P[1]；输出 |

Ctx0：末输入 C6，raw 完成 C11；Ctx1：末输入 C7，raw 完成 C12。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

| 输入周期 | wgt_raddr | ACT | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C0 | 8'h20 | 采样 A0(T0) | C5 | 初次填充: R → P[0] |
| C1 | 8'h21 | 复用 A0(T0) | C6 | 初次填充: R → P[1] |
| C2 | 8'h20 | 采样 A1(T0) | C7 | fusion: P[0] + (R << 4) → P[0] |
| C3 | 8'h21 | 复用 A1(T0) | C8 | fusion: P[1] + (R << 4) → P[1] |
| C4 | 8'h20 | 采样 A2(T0) | C9 | fusion: P[0] + (R << 8) → P[0] |
| C5 | 8'h21 | 复用 A2(T0) | C10 | fusion: P[1] + (R << 8) → P[1] |
| C6 | 8'h20 | 采样 A3(T0) | C11 | fusion: P[0] + (R << 12) → P[0] |
| C7 | 8'h21 | 复用 A3(T0) | C12 | fusion: P[1] + (R << 12) → P[1] |
| C8 | 8'h30 | 采样 A0(T1) | C13 | acc: P[0] + R → P[0] |
| C9 | 8'h31 | 复用 A0(T1) | C14 | acc: P[1] + R → P[1] |
| C10 | 8'h30 | 采样 A1(T1) | C15 | fusion: P[0] + (R << 4) → P[0] |
| C11 | 8'h31 | 复用 A1(T1) | C16 | fusion: P[1] + (R << 4) → P[1] |
| C12 | 8'h30 | 采样 A2(T1) | C17 | fusion: P[0] + (R << 8) → P[0] |
| C13 | 8'h31 | 复用 A2(T1) | C18 | fusion: P[1] + (R << 8) → P[1] |
| C14 | 8'h30 | 采样 A3(T1) | C19 | fusion: P[0] + (R << 12) → P[0]；输出 |
| C15 | 8'h31 | 复用 A3(T1) | C20 | fusion: P[1] + (R << 12) → P[1]；输出 |

Ctx0：末输入 C14，raw 完成 C19；Ctx1：末输入 C15，raw 完成 C20。

## 附录 B 规范 split 编码

以下按 bit6..bit0 给出26种规范编码，K 限制还需结合 precision、EN 和 OC：

`0000000`、`0000001`、`0000011`、`0000101`、`0000111`、`0001011`、`0001111`、`0010011`、`0010111`、`0011011`、`0011111`、`0100101`、`0100111`、`0101111`、`0110111`、`0111111`、`1000101`、`1000111`、`1001111`、`1010111`、`1011111`、`1100101`、`1100111`、`1101111`、`1110111`、`1111111`
