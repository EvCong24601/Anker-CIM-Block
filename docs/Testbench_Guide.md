# 仿真 Testbench 阅读与修改指南

TB 按“状态与连接 → 参考模型 → 输入驱动 → 检查器 → case → suite → 启动入口”组织。顶层仍为 tb_Cluster、tb_SingleMacro、tb_ClusterReduceTree；拆分使用 module 内的 include，不增加层次，既有波形路径和 latency_audit 的观察路径继续有效。

## Cluster

功能源码集中在 RTL/cluster/rtl，所有验证源码集中在 RTL/cluster/tb；完整结构见 [Cluster 目录说明](../RTL/cluster/README.md)。

`RTL/cluster/rtl/cluster_pkg.sv` 是共享 package，定义 cluster_ctrl_t 和精度/归约辅助函数，供 Cluster 参考实现、归约树与 TB 共同 import。它不是独立模块，必须在引用它的源文件之前编译；命名不限定为 TB 专用。

从 `RTL/cluster/tb/tb_Cluster.sv` 开始阅读。该文件只保留参数、时钟、接口、DUT、参考状态与计数器，以及有序 include 列表。验证片段位于相邻 `include/` 目录：

- `cluster_reference.svh`：随机数据、精度边界、独立树分组、OC 有效路径、lane 时延。golden 路径用于独立判断贡献，不能直接复用 DUT 的结果作为预期。
- `cluster_driver.svh`：Command 的 SEND/ACCEPT 日志、输入握手、完整 ACT 包和 AS 后续地址的驱动。驱动在下降沿更新；Command 在上升沿接受，ACT 尾部 Plane 连续输入。
- `cluster_scoreboards.svh`：四个并行检查器，分别检查 ACT bank、tmp/Psum 的 ICG 和保持、逐 phase 算术历史、命令及最终 raw 输出。先按边沿前状态预测，再在 NBA 更新后核对寄存器；其中的短延迟用于避免仿真采样竞争，不代表硬件流水级。
- `cluster_compute_cases.svh`：一个 `run_case` 的完整生命周期：配置与开始日志、生成 ACT、预加载权重并计算独立整数点积、驱动任务、等待输出、核对计数和排空。
- `cluster_sram_cases.svh`：常规 SRAM 写/读任务、逐字节独立镜像、写后计算检查，以及全地址/全掩码/隔离/复位/连续访问场景。
- `cluster_suites.svh`：计算场景目录，命名任务分别枚举 OC merge、ACT 容量、完整 ACT、混合 Context、输入重叠和默认回归。这里决定“跑哪些 case”，不实现第二套驱动或 scoreboard。
- `cluster_regression.svh`：唯一 initial 启动入口、plusarg 分派、CSV 创建/关闭、总覆盖检查、watchdog 和 FSDB。SRAM 专项在打开默认 CSV 前分派。

`monitoring` 只控制计算类 scoreboard 的 case 检查窗口，SRAM 专项有自己的读回镜像与计算检查。`expected` 是独立数值预期，`lane_due` 是预期输出周期，`raw_seen` 检查重复发布；它们均为 TB 状态，不是产品硬件寄存器。

`latency_audit.sv` 位于验证 RTL/cluster/tb/，通过 tb_Cluster 层次引用观察 Command、最后一次内部发射及 Context 输出完成周期，写出 CSV，供 audit_latency.py 核对；它不驱动 DUT，也不属于综合源码。

`tb_ClusterReduceTree.sv` 保留为一个小型独立 TB，并按接口/预期状态、递归参考、驱动对齐、tap/门控检查、208 个场景枚举分段注释。它不依赖 Cluster 的 ACT/Context 调度。

## SingleMacro

`RTL/macro/tb/tb_SingleMacro.sv` 保留 DUT 与独立乘法 primitive 实例、接口及参考状态。相邻 `include/` 中：

- `macro_reference.svh`：随机输入与完整整数权重解码的独立点积 golden。
- `macro_driver.svh`：case 开始日志、写行、计算 phase、空拍、排空和异步复位任务。
- `macro_scoreboard.svh`：逐 OC 权重写镜像、Hold 刷新/复用历史、固定一拍结果及输出保持检查。
- `macro_negative_cases.svh`：15 类故意违反协议的 case；每例必须命中指定 SM_PROTOCOL 诊断，不能将出现任意 Fatal 当作通过。
- `macro_regression.svh`：primitive 穷举、256 行预加载、精度/符号/phase/mask 穷举、极值、Hold、随机、读回、复位等正向场景，以及最终计数检查和 watchdog。

SRAM 初始化状态的逐 OC 跟踪位于 RTL 的仿真检查分支，受 SINGLE_MACRO_ASSERTIONS 控制，综合时排除；它不是 TB 为硬件增加的有效位。

## 新增 case 的位置

Requant功能实现位于 `RTL/cluster/rtl/ClusterRequant.sv`，无时钟纯组合；`cluster_dut_adapter.sv`负责batch配置锁存和INT8输出寄存器。量化valid严格比raw晚一拍。`tb_ClusterRequant.sv`使用Python任意精度整数向量，`cluster_requant_cases.svh`负责集成golden、配置锁存、延迟、保持、复位和跨batch边界检查。详细参数与测试范围见 [Requant说明](Cluster_Requant.md)。

`tb_Cluster_GEMM_OS1_WS32.sv`仅实例化一个Cluster，分四批N4计算完整32×128乘128×16。`cluster_gemm_driver.svh`负责向量读取、打包核对、四行SRAM预加载和WS32驱动；`cluster_gemm_scoreboard.svh`检查地址/发射/权重Hold/输出矩阵及延迟；`cluster_gemm_regression.svh`负责四批调度、输出拼接和覆盖检查。`gemm_vectors.py`先从原始实数矩阵生成golden及校准参数，再输出物理激励；SV不共享Python的矩阵打包算法。详见 [GEMM说明](Cluster_GEMM_WS32.md)。

`tb_Cluster_GEMM_OS2_AS4.sv`是独立的M32/K512/N16矩阵TB，`cluster_gemm_as_driver/scoreboard/regression.svh`分别负责8个权重地址和Command/ACT、4096次Psum历史及逐Context输出、32行batch调度与矩阵收集。`gemm_os2_as4_vectors.py`生成golden，AS4的五个VCS case运行两个weight版本及3个配置负向场景；`make regression`包含全部GEMM。输入offset已合入逐通道zp，AS Context首K Tile的Command加载各组zp。详见 [OS2 AS4说明](Cluster_GEMM_OS2_AS4.md)。

计算新配置通常只需在 `cluster_suites.svh` 的对应 suite 调用 `run_case`。需要新的输入驱动方式时修改 driver；需要新判定规则时修改 scoreboard，并保留独立预期。常规读写场景放在 `cluster_sram_cases.svh`；单 Macro 非法输入放在 `macro_negative_cases.svh`，同时为 Python 回归入口补充精确诊断匹配。

所有 case 在开始时输出 `[CASE_START] time=... ns suite=... description=...`。新增独立场景应沿用该格式，描述测试目的并列出关键参数。现有 Command 日志仍用于区分“何时驱动”和“何时真正接受”。

## 编译和回归

`.svh` 仅由顶层 include，不要逐个加入源文件列表。必须保留对应 TB 父目录的 include 搜索路径：

- Cluster 的 `filelist.f` 使用 `+incdir+.`，从 RTL/cluster/tb 目录运行。
- Macro 的 `tb/filelist.f` 从 macro 目录运行，使用 `+incdir+tb`。
- VCS 的两个文件列表分别增加 Cluster tb 或 Macro tb 的 include 目录，从 vcs-rtl 目录运行。
- Python 入口复制 `.svh` 的目录结构并记录源码 SHA256，随后从副本编译，避免漏拷 include 或读到另一份旧源码。

从 vcs-rtl 目录执行：

VCS 运行入口及各 case 的参数见 [vcs-rtl 使用说明](../vcs-rtl/README.md)。

`make regression`包含常规 SRAM、2 类冲突、SingleMacro 门控开/关、15 类协议负向检查，以及默认 Cluster 1368 例、归约树 208 例、OC merge 288 例、ACT 容量 280 例、完整 ACT 12 例和混合 Context 24 例、大 Context 正向 224 例、容量负向 18 例和包内输入重叠 168 例。各专项 CSV 分目录存放，默认计算 suite 的 CSV 得以保留。

`make regression`包含Requant独立9,611个算术向量及512个四通道向量、168个per-tensor集成case、1536个per-channel集成case、reset、跨batch参数切换和7个精确配置负向诊断。raw-only suite保持ENABLE_REQUANT=0；量化专项开启为1并检查数值和1T延迟。AS参数在首K Tile加载、后续Tile核对一致。

VCS 仍使用 `make com`、`make sim`；`make sram` 运行 SRAM 专项，`make com sim TB=macro` 运行单 Macro。也可通过 `PVALUE=+OC_MERGE_TEST` 等 plusarg 选择专项。

## 回归输出格式

正向测试和正确捕获预期错误的负向测试统一以 PASS 开头；意外错误、漏报或不同于预期的诊断仍判为 FAIL。负向测试摘要使用明确的英文格式：

```text
PASS macro_negative_read_write: caught expected SM_PROTOCOL: simultaneous read/write
PASS macro_negative_write_busy: caught expected SM_PROTOCOL: write before pipeline drain
PASS regression: suites=50 expected_rejections=38
```

单个仿真的原始日志保留真实 Fatal，便于定位断言触发位置；控制台和 validation.log 的汇总将它标明为预期捕获。SV 的 display/诊断字符串及 case 描述使用英文，源代码中的中文解释注释不受影响。

## 大 Context 与 Psum 容量专项

专项分别运行 OS1/WS64、OS1/AS64、OS2/WS8 和 OS2/AS8，WS/AS 不同时大于 1。Psum 深度固定为 16。`WGT_RADDR_BUFFER_DEPTH=64` 定义供所有 AS 模式共用的 64 项权重行地址表，每项仅 8 bit，共 512 bit（64 B）；`MAX_CONTEXTS=64` 定义标签/完成状态容量，二者与 Psum 深度独立。

仅 OS1 AS 改为 Context→Slice：先在每 OC 唯一 tmp 中融合一个 Context 的全部 slice，再切换 Context。因此 OS1 AS64 的 A4/A8/A16 全部合法，不读写 Psum。OS>1 AS 保留 Slice→Context 顺序：同一 slice 遍历所有 Context，再进入下一 slice，融合历史及跨 Tile 累加仍保存在 Psum。OS2 AS8 合法，OS2 AS64 仍超过 Psum 深度 16。

OS1 和 OS>1 的 AS 都需要地址表：OS1 在同一 Context 的多个 slice 间保持地址，再切换下一个地址；OS>1 每轮 slice 都重访各 Context 地址。表中保存行号，不保存权重数据，权重仍预先装载在 Macro SRAM；不需要为八个 Macro 各复制一份表，因为计算端使用共享 8-bit 行地址。

正向共 224 例：OS1 WS64、OS1 AS64、OS2 WS8、OS2 AS8 各 56 例，覆盖七精度、UINT/INT、随机/交替极值及有无 Command 空拍。OS1 AS64 检查所有 64 个 Context 的结果，且 Psum 整批保持关闭。另有 14 个 OS2 AS64 容量负向例（七精度×两种符号），以及地址深度 32、标签容量 32 时请求 AS64 的各两例，要求命中各自准确诊断。

VCS 运行入口及各 case 的参数见 [vcs-rtl 使用说明](../vcs-rtl/README.md)。

默认地址表与标签容量均为 64，Psum 深度为 16；VCS 可用 `make sim PVALUE=+CONTEXT_STRESS_TEST` 选择正向专项。`+CONTEXT_CAPACITY_TEST` 默认验证 OS2 AS64；`+CAPACITY_PRECISION=0..6` 和 `+CAPACITY_SIGN=0/1` 选择精度与符号。追加 `+ADDRESS_CAPACITY_TEST` 或 `+METADATA_CAPACITY_TEST` 验证 OS1 AS64 的独立资源限制，参数相应配置为 32。完整自动判定由 Python 入口执行。
## 同包输入与发射重叠

规则与公式见 [Cluster 输入重叠说明](Cluster_Input_Overlap.md)。`cluster_scoreboards.svh` 逐沿检查当前Plane及地址就绪条件；`run_case` 强制覆盖多slice采样/发射重叠、连续AS地址/发射重叠、有空拍时等待地址，以及首命令后一拍发射。`+INPUT_OVERLAP_TEST` 专项168例由 `make regression` 自动执行，也可用 `CASE=input_overlap` 单独追加运行。Python `buffer_schedule.py` 和 README 生成器共用更新后的无空拍公式。

## 8-bit count 边界

os_cnt/ws_cnt/as_cnt 均为8 bit，合法字段值为1～255，0非法；packed descriptor总宽107 bit。实际WS/AS仍受容量限制。`+OS_COUNT_LIMIT_TEST`覆盖12个OS255非零累加case：W2A4/A8、UINT/INT、单Context/WS2/AS2；使用固定极值权重以允许8-bit行地址回绕后重访相同内容。`+ZERO_COUNT=0/1/2`分别拒绝OS/WS/AS为0。`make regression`自动包含这些检查，回归数量以log/four_channel_validation.log为准。

## 四通道 Requant 与 weight per-channel

新增端到端场景使用tb_Cluster_GEMM_Edges.sv，分离driver、scoreboard和regression三个include。make gemm-regression运行七组，覆盖W4A16 Macro4～7、W2A8 Macro6～7、N6带OC空洞的尾部，以及实际矩阵产生的舍入/饱和边界。详见[GEMM边界场景](Cluster_GEMM_Edges.md)，make regression自动包含。

详见[Requant说明](Cluster_Requant.md)。tb_Cluster的raw-only suite默认ENABLE_REQUANT=0，量化专项通过参数覆盖为1，检查单归约组和最多4OC。两个GEMM TB均保留per-tensor weight并新增+PER_CHANNEL_SCALE版本；Python对每列W分别量化并生成独立参数/golden。所有版本的合并zp仍为per-channel，仅四项，按固定OC索引选择。
