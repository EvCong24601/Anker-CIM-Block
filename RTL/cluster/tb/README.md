# Cluster testbench：tmp、bit fusion、Psum acc 与 ICG

参考 adapter 连接八个真实 SingleMacro RTL，保留 raw signed32，新增 per-tensor 组合 Requant 与32×8-bit输出寄存器，量化valid比raw晚一拍。尚未综合、映射工艺库 ICG、运行 STA 或门级功耗验证。公式、配置和测试见 [Requant说明](../../../docs/Cluster_Requant.md)。

每个 merge 节点采用其固定最左侧 Macro 的 OC mask，组内 mask 可以不同。t5、t2 均取 M4，t0 取 M0；不回退到首个使能 Macro。被屏蔽子树不贡献数据，转发门控、终点 mask 与批次输出预留采用相同规则。全部 OC 被屏蔽的批次在内部发射完成后结束，不产生输出脉冲。本地 `--gate-unit --oc-merge` 可运行 208 例归约单元测试及 288 例独立 mask 专项测试。

mask 来源完整映射：`t3←M0, t4←M2, t5←M4, t6←M6, t1←M0, t2←M4, t0←M0`。父节点继承左子树的 mask；例如 t2 通过 t5 继承 M4，即使 M5、M6、M7 的 mask 不同也不改变来源。已编译的 VCS Cluster 仿真可用 `make sim PVALUE=+OC_MERGE_TEST` 运行专项测试，日志应包含 `PASS oc_merge_leftmost cases=288`。

外部 ACT 为1024-bit Plane 流：首个 i_cmd 接受沿接收A0，随后P−1个周期连续接收A1..A(P−1)，P=A位宽/4；无 ACT 握手。完整数据保存于4096-bit act_buffer，当前Plane寄存后即可按precision、counts和slot分发。

WS每个Tile/Context加载一个完整ACT并发送一次Command。AS每个Tile仅加载一次完整ACT，各Context仍各发送一次带自身权重地址的Command；后续地址命令可与ACT后续Slice重叠。内部发射仅等待当前Plane与当前Context地址有效，可与同包后续Plane及AS地址接收重叠，首命令尚未接受时保持Command+A0；剩余ACT流一旦开始就逐拍接收。OS1 AS 采用 Context→Slice，OS>1 AS 保留 Slice→Context；地址暂存表供所有 AS 模式共用，默认 64×8 bit。

Context是同一channel内独立保存、独立输出的计算任务，Psum[ctx]为其深度位置。WS的Context对应不同ACT，AS的Context对应不同权重地址；os表示每个Context累加的K Tile数。各Context不互相相加。术语、外部接收和内部发射的逐拍表见[仓库首页](../../../README.md)。

## 常规 SRAM 与 case 开始日志

常规读写接口通过 `{cim_macro_group,cim_bank_sel}` 选择一个 Macro，由 cim_row_addr 选择四个 OC 共用的 128 B 行。cim_wmask 每位为 1 屏蔽对应 OC 的 32 B，为 0 允许写入；读忽略该掩码。TB preload 保留为独立验证辅助接口。接口时序、互斥约束和测试覆盖见 [常规权重 SRAM 规格](../../../docs/Cluster_Weight_SRAM_Interface.md)。

从仓库根目录执行 `python RTL/cluster/tb/py/run_sram_regression.py --full`；VCS 使用 `make sram` 或 `+SRAM_RW_TEST`。SRAM 专项在打开标准 CSV 前运行，不覆盖原计算回归的数据文件。

每个 Cluster、SRAM、归约树及 SingleMacro case 开始都会输出 `[CASE_START] time=... ns suite=... description=...`，包含当前仿真时间和场景/参数；CMD_SEND、CMD_ACCEPT 继续独立记录命令驱动和接受时间。

## TB 文件拆分

顶层 tb_Cluster.sv 只保留连接与共享状态；include/ 按职责拆分，新增 cluster_requant_cases.svh 负责量化golden、参数profile、1T延迟/输出保持检查和专项case。先从 cluster_suites.svh 找原有场景；Requant专项从对应include阅读。文件职责、采样顺序与新增 case 方法见 [Testbench 阅读指南](../../../docs/Testbench_Guide.md)。.svh 不单独编译，文件清单和 Python 副本入口已配置 include 路径。

功能源码在 [../rtl/](../rtl/)，文件职责与整体结构见 [Cluster 目录说明](../README.md)。

## 目录与入口

Git仓库提供[VCS入口](../../../vcs-rtl/Makefile)，在vcs-rtl目录运行make com、make sim、make check。ModelSim专用py/run_regression.py仅保留在本地，不纳入Git；下文该脚本的命令用于记录本地验证方法。共用SV/TB与数据检查Python仍纳入Git。

```text
tb/
  tb_Cluster.sv             Cluster 仿真顶层
  tb_ClusterReduceTree.sv   归约树单元测试
  tb_ClusterRequant.sv      无时钟Requant算术单元测试
  tb_Cluster_GEMM_OS1_WS32.sv        单Cluster两批N8，W8A16 M32/K128/N16 WS32矩阵
  tb_Cluster_GEMM_OS2_AS4.sv 单Cluster八Macro全归约，W8A16 M32/K512/N16
  latency_audit.sv          时延观察器
  include/                 驱动、golden、scoreboard、case 和 suite
  py/         split/逐拍生成器、时延检查器
  log/        回归日志与时延核对报告
  data/       split 配置、逐拍事件、实测时延 CSV
  filelist.f  相对当前 tb 目录的完整 SV 文件列表
  README.md
```

在本目录执行 `python py/run_regression.py --gate-unit --mixed-context --full-act --act-buffer --latency-audit --log regression_act_capacity_default.log`。脚本也可从仓库根目录或其他目录调用；入口把源码和检查脚本复制到仓库外的 cluster_tb_work/local_sim/<日志名>，work、CSV、日志和波形均在副本内生成；--sim-dir 可指定仓库外目录。该副本不提交 Git，仓库 data/log 仅保存经核对的结果。

## 流水与存储

调试日志默认逐条打印外部 i_cmd：`[CMD_SEND]` 为 TB 拉高 `cmd_valid_i` 的时刻，`[CMD_ACCEPT]` 为 `cmd_valid_i && cmd_ready_o` 的接受沿；时间戳明确使用 ns。每行包含 case、standard_case、命令序号、Tile/Context、ACT/ADDRESS 类型、WS/AS/SINGLE 模式、完整 descriptor 配置及 pattern、bubbles、Psum depth、seed。case、cmd、tile、context 均从 0 开始；case 与 scoreboard 报错编号一致，standard_case 保留原有六种标准时序编号（其他 case 为 0）。等待 ready 时不会重复打印 SEND，可对照同一 case/cmd 的两行定位停顿；AS 后续地址命令也会打印。

每个OC仅一个32-bit tmp数据寄存器，以及深度 OUTPUT_BUFFER_DEPTH（默认16）的32-bit Psum Context buffer。每 OC 共用一套 fusion 和一套 acc；同一 OC 每拍仅选择一个 Context entry，其他深度保持。

WS/单 Context 与 OS1 AS：归约 R_slice 与旧 tmp 做融合后写入 tmp，A0 直接覆盖；下一拍消费 tmp。os=1 最后 phase 直接输出，不写 Psum；os>1 仅最后 phase 填充或累加 Psum[ctx]。旧 tmp 的 acc 与新归约数据的 fusion 可同拍位于 tmp 两侧，属于不同输入结果。

OS>1 AS：归约 R_slice 先写 tmp，下一拍首 Tile/A0 填充 Psum[ctx]，后续 Tile/A0 做 acc，高 phase 做 fusion。保留 Slice→Context 的调度。OS1 AS 在 tmp 前完成逐 Context 的 bit fusion，所有精度均旁路 Psum。

门控：tmp_input_cg_en 提前 tmp 捕获一拍；psum_cg_en 在捕获 tmp 时预测下一拍的唯一 Context 写回。首 Command 开放低 max(ws,as) 个所需 Psum entry，高地址整批关闭；所有 os=1 模式全关。门控请求逐 OC 至多一位有效，实际 ICG 时钟与关闭 DFF 保持由 TB 检查。

同一结果的 fusion 和 acc 不串联。WS/OS1 AS 归约末级与 fusion 在 tmp 前的路径需要 STA；OS>1 AS 在 tmp 后二选一。未用组合块两个输入隔离为零。存储tmp/Psum为32 bit，组合参考计算及TB golden使用64-bit longint；Requant使用signed64乘积和signed96组合中间值，输出INT8寄存器；未做生产综合/STA/功耗签核。

## Reduce tree 与时延

t1..t6 是向父级转发的 DFF。Pair 结束时从 t3..t6 前取数并关闭转发 DFF；quad 结束时从 t1/t2 前取数并关闭它们；仅继续归约时打开。`reduce_cg_en` 仍提前 1T，接 ICG。没有独立 root-only DFF 或统一末级对齐流水。

从实际 Macro 发射 Cq：叶子/pair 在 C(q+2) 捕获 tmp、C(q+3) 运算完成；quad 在 C(q+3)/C(q+4)；root 在 C(q+4)/C(q+5)。标准 W2/W4/W8 从末内部发射到raw的延迟为 **3T/4T/5T**。混合树各 channel 按自身深度直接发布各自 lane，浅层 lane 不等深层，同 lane 按 Context 顺序发布。同批 Context 使用同一 descriptor 布局。输入停顿和 requant 不含在上述周期中。

## 六种配置与清单

case 1..6 为：`(os,ws,as)=(1,1,1)、(1,1,2)、(1,2,1)、(2,1,1)、(2,2,1)、(2,1,2)`。七种 precision 各展开六例，共 42 个操作表；INT×INT/UINT×UINT 共用时序。

运行生成器后，`data/buffer_cycle_cases.txt` 逐行列出 tmp 数据、操作、深度和写回时刻。[buffer_cycle_cases.csv](data/buffer_cycle_cases.csv) 提供完整 split/group 枚举。仓库主 README 的附录 A 按六种配置、七种精度列出 外部ACT接收、内部发射、权重地址、运算和结果位置。

`py/buffer_schedule.py` 从 `data/split_cases.csv` 将所有合法 split/sign 配置展开为六种配置，生成 `data/buffer_cycle_cases.csv`。默认 200×6=1200 个组合、44280 个有效 group 事件。这是无停顿逻辑时序枚举，不等于额外仿真了1200组。[buffer_operations.csv](data/buffer_operations.csv) 是实际标准仿真记录，无停顿版本核对480个运算事件：

```text
python py/buffer_schedule.py --trace data/buffer_operations.csv
```

三个 count 最小为1。ws>1/as=1为WS，as>1/ws=1为AS，二者为1则单Context，不定义同时>1。precision 0..6为W2A4、W2A8、W4A4、W4A8、W4A16、W8A8、W8A16。A0..A3为4-bit slice，INT仅最高有效slice按signed4。WS及OS1 AS顺序为Tile→Context→phase，OS>1 AS为Tile→phase→Context。

descriptor为107bit，包含共享8-bit weight_cim_raddr与32-bit macro_oc_mask。每Tile/Context提交一次Command；首个Context命令同拍提供A0，其他Slice连续接收；AS其余Context各提交地址命令。内部所有phase由已保存descriptor和act_buffer驱动。同地址有效Hold用cim_station=0，首读/换地址/写入后刷新。标准映射：W2 slots=[0,1,0,1,0,1,0,1]/split07/EN55；W4 slots=[0,1,2,3,0,1,2,3]/split01/EN33；W8 slots=[0,1,2,3,4,5,6,7]/split00/EN0F。每组K128，ACT高512bit补零。WS地址T0=20/T1=30，AS的T0 Ctx0/1=20/21、T1=30/31，均为8-bit十六进制。

psum_data_o 输出 raw signed32（1024 bit，32 channel）；out_valid_o 每 OC 一位，写回即置位一拍；不同 Context 独立，不包含 requant。

## 验证

完整 case 分类、六种数据 pattern、各精度 split 数量和参数作用范围见 [仓库首页的 tb_Cluster 测试 case](../../../README.md#tb_cluster-测试-case)。

```text
python py/run_regression.py --gate-unit --mixed-context --full-act --act-buffer --latency-audit --log regression_act_capacity_default.log
python py/run_regression.py --en a5 --oc 84218421 --depth 3 --full-act --mixed-context --latency-audit --log regression_act_frame_sparse_depth3.log
```

默认1368个Cluster case：1200穷举数据case、84标准时序case、28 Command空拍/多Context交错case、56三Tile/三Context极值case。另有208个reduce-tree门控单元case。EN=FF时每符号合法split数为1,1,16,16,16,25,25，每组有效K严格小于256。完整ACT加载后改变外部ACT，逐digit检查内部计算使用act_buffer。--full-act另加12个W8A16全4096-bit、八Macro root归约K256定向case。

检查独立整数点积、每channel到达周期、WS唯一tmp状态、AS（含os=1融合）的逐phase Psum历史、旁路 case 的 Psum保持、未用加法器输入隔离、真实ICG时钟、关闭DFF保持、高地址深度整批关闭和按序发布。`--latency-audit` 启用 `latency_audit.sv`，采集 [latency_audit.csv](data/latency_audit.csv) 的140个标准Context输出；`py/audit_latency.py` 按六种配置公式核对，生成 [latency_audit_validation.log](log/latency_audit_validation.log)。Python检查器只依赖标准库，无需本地Word文档。

要求 ModelSim 的 vlib/vlog/vsim 在 PATH。Python 入口分别读取 ../rtl/ 中的功能源码和 当前目录中的验证源码，并自动定位 `../../macro/rtl`；也可用 `--macro-rtl PATH` 指定。`filelist.f` 可从本目录手动编译，仿真时选择具体顶层。`+DATA_DIR=路径` 控制 SV 的 CSV 输出位置，Python 入口自动传入本地副本的绝对 data 路径；直接运行 TB 时默认当前工作目录。

OS_TILES 控制穷举 suite，范围1..14。UINT W8A16 的 ACT 限制到0..32768/os_cnt-1，使最终结果保持 signed32。验证入口对应的日志为 `log/regression_act_capacity_default.log`、`log/regression_act_capacity_default_reduce_gate.log`、`log/regression_act_frame_sparse_depth3.log` 和 `log/latency_audit_validation.log`。

混合 Context 定向 suite 通过 --mixed-context 启用，额外24例覆盖 W4A4/A8/A16、两种符号、os=1/2、WS/AS双 Context，以及 pair/quad 同拍发布不同 Context。内部 Context 标签按 lane 保存。FSDB 由 CLUSTER_FSDB 宏控制，VCS Makefile 开启；ModelSim 默认不开启。--depth 设置 OUTPUT_BUFFER_DEPTH，--psum-depth 为同一参数的命令行别名。

Cluster 数据 DFF 分布见[仓库首页](../../../README.md#cluster-数据-dff-位置)：ACT4096、归约中间级464、唯一tmp1024、Psum1024×OUTPUT_BUFFER_DEPTH、raw输出保持1024 bit、INT8输出保持256 bit；不含控制寄存器及SingleMacro内部。

外部输入实测见[external_inputs.csv](data/external_inputs.csv)，含396条标准输入事件；act_sample是日志标记，并非输入pin。所有C周期以首个外部i_cmd+A0为C0；latency_audit.csv的last_input是末内部发射，delta为内部路径3/4/5T。整批完成周期按同包重叠公式计算，地址空拍按就绪条件延长；单bank在内部发射结束后接收下一包。

WS每Tile有效计算为P×ws_cnt拍，P=A位宽/4；ws_cnt仍是完整ACT/Context数，Psum深度不乘phase。单bank支持同包输入与发射重叠，无空拍时每Tile占(P+1)×ws_cnt个时钟沿。

容量结论：完整ACT为256×A位宽bit，最大4096；WS逐Context换入，AS跨Context保持同一份ACT，OS逐Tile换入。因此容量不乘ws/as/os。必须遵守首命令ready及后续ACT连续输入，单bank不支持接收下一包与内部发射重叠。--act-buffer提供280个全Plane容量case，覆盖七精度、两种符号、os1/2、1/2/16 Context及命令空拍。

raw_data每OC 32 bit（共1024 bit），额外requant_data_o每OC 8 bit（共256 bit输出寄存器）。raw在Ck发布，量化在C(k+1)发布；无valid时各lane独立保持，reset清零。Requant内部没有数据流水寄存器。

## 回归输出格式

正向测试和正确捕获预期错误的负向测试统一以 PASS 开头；意外错误、漏报或不同于预期的诊断仍判为 FAIL。负向测试摘要使用明确的英文格式：

```text
PASS macro_negative_read_write: caught expected SM_PROTOCOL: simultaneous read/write
PASS macro_negative_write_busy: caught expected SM_PROTOCOL: write before pipeline drain
PASS regression: suites=37 expected_rejections=27
```

单个仿真的原始日志保留真实 Fatal，便于定位断言触发位置；控制台和 validation.log 的汇总将它标明为预期捕获。SV 的 display/诊断字符串及 case 描述使用英文，源代码中的中文解释注释不受影响。

## 大 Context 与 Psum 容量专项

专项分别运行 OS1/WS64、OS1/AS64、OS2/WS8 和 OS2/AS8，WS/AS 不同时大于 1。Psum 深度固定为 16。`WGT_RADDR_BUFFER_DEPTH=64` 定义供所有 AS 模式共用的 64 项权重行地址表，每项仅 8 bit，共 512 bit（64 B）；`MAX_CONTEXTS=64` 定义标签/完成状态容量，二者与 Psum 深度独立。

仅 OS1 AS 改为 Context→Slice：先在每 OC 唯一 tmp 中融合一个 Context 的全部 slice，再切换 Context。因此 OS1 AS64 的 A4/A8/A16 全部合法，不读写 Psum。OS>1 AS 保留 Slice→Context 顺序：同一 slice 遍历所有 Context，再进入下一 slice，融合历史及跨 Tile 累加仍保存在 Psum。OS2 AS8 合法，OS2 AS64 仍超过 Psum 深度 16。

OS1 和 OS>1 的 AS 都需要地址表：OS1 在同一 Context 的多个 slice 间保持地址，再切换下一个地址；OS>1 每轮 slice 都重访各 Context 地址。表中保存行号，不保存权重数据，权重仍预先装载在 Macro SRAM；不需要为八个 Macro 各复制一份表，因为计算端使用共享 8-bit 行地址。

正向共 224 例：OS1 WS64、OS1 AS64、OS2 WS8、OS2 AS8 各 56 例，覆盖七精度、UINT/INT、随机/交替极值及有无 Command 空拍。OS1 AS64 检查所有 64 个 Context 的结果，且 Psum 整批保持关闭。另有 14 个 OS2 AS64 容量负向例（七精度×两种符号），以及地址深度 32、标签容量 32 时请求 AS64 的各两例，要求命中各自准确诊断。

```text
python RTL/cluster/tb/py/run_sram_regression.py --full
python RTL/cluster/tb/py/run_sram_regression.py --context-stress
```

默认地址表与标签容量均为 64，Psum 深度为 16；VCS 可用 `make sim PVALUE=+CONTEXT_STRESS_TEST` 选择正向专项。`+CONTEXT_CAPACITY_TEST` 默认验证 OS2 AS64；`+CAPACITY_PRECISION=0..6` 和 `+CAPACITY_SIGN=0/1` 选择精度与符号。追加 `+ADDRESS_CAPACITY_TEST` 或 `+METADATA_CAPACITY_TEST` 验证 OS1 AS64 的独立资源限制，参数相应配置为 32。完整自动判定由 Python 入口执行。
## 同包输入与发射重叠专项

`+INPUT_OVERLAP_TEST` 运行168例：七精度×两种符号×OS1/2×单Context/WS2/AS2×有无地址空拍。检查A8/A16加载期间发射、AS地址接收与发射同拍、地址延迟时暂停及恢复、首发射为C1、数值与逐lane输出时延。输入仍先寄存，当前包发完后才接收下一包。

```text
python RTL/cluster/tb/py/run_sram_regression.py --input-overlap
```

`--full` 自动包含该专项。精确规则、周期公式及示例见 [Cluster 输入重叠说明](../../../docs/Cluster_Input_Overlap.md)。

仅 OS1 的 AS 逐 Context 完成 bit fusion；OS>1 AS 保留原调度。所有 AS 模式均使用地址暂存表，详见 [OS1 AS 融合与权重地址暂存](../../../docs/Cluster_AS_OS1_Fusion.md)。
