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

计算新配置通常只需在 `cluster_suites.svh` 的对应 suite 调用 `run_case`。需要新的输入驱动方式时修改 driver；需要新判定规则时修改 scoreboard，并保留独立预期。常规读写场景放在 `cluster_sram_cases.svh`；单 Macro 非法输入放在 `macro_negative_cases.svh`，同时为 Python 回归入口补充精确诊断匹配。

所有 case 在开始时输出 `[CASE_START] time=... ns suite=... description=...`。新增独立场景应沿用该格式，描述测试目的并列出关键参数。现有 Command 日志仍用于区分“何时驱动”和“何时真正接受”。

## 编译和回归

`.svh` 仅由顶层 include，不要逐个加入源文件列表。必须保留对应 TB 父目录的 include 搜索路径：

- Cluster 的 `filelist.f` 使用 `+incdir+.`，从 RTL/cluster/tb 目录运行。
- Macro 的 `tb/filelist.f` 从 macro 目录运行，使用 `+incdir+tb`。
- VCS 的两个文件列表分别增加 Cluster tb 或 Macro tb 的 include 目录，从 vcs-rtl 目录运行。
- Python 入口复制 `.svh` 的目录结构并记录源码 SHA256，随后从副本编译，避免漏拷 include 或读到另一份旧源码。

从仓库根目录执行：

```text
python RTL/cluster/tb/py/run_sram_regression.py --full
```

默认执行常规 SRAM、2 类冲突、SingleMacro 门控开/关和 15 类协议负向检查。`--full` 追加默认 Cluster 1368 例、归约树 208 例、OC merge 288 例、ACT 容量 280 例、完整 ACT 12 例和混合 Context 24 例、大 Context 正向 184 例、容量负向 10 例和包内输入重叠 168 例。各专项 CSV 分目录存放，默认计算 suite 的 CSV 得以保留。

VCS 仍使用 `make com`、`make sim`；`make sram` 运行 SRAM 专项，`make com sim TB=macro` 运行单 Macro。也可通过 `PVALUE=+OC_MERGE_TEST` 等 plusarg 选择专项。

## 回归输出格式

正向测试和正确捕获预期错误的负向测试统一以 PASS 开头；意外错误、漏报或不同于预期的诊断仍判为 FAIL。负向测试摘要使用明确的英文格式：

```text
PASS macro_negative_read_write: caught expected SM_PROTOCOL: simultaneous read/write
PASS macro_negative_write_busy: caught expected SM_PROTOCOL: write before pipeline drain
PASS regression: suites=38 expected_rejections=27
```

单个仿真的原始日志保留真实 Fatal，便于定位断言触发位置；控制台和 validation.log 的汇总将它标明为预期捕获。SV 的 display/诊断字符串及 case 描述使用英文，源代码中的中文解释注释不受影响。

## 大 Context 与 Psum 容量专项

专项分别运行 OS1/WS64、OS1/AS64、OS2/WS8 和 OS2/AS8，WS/AS 不同时大于 1。Psum 深度固定为 16；专项仅将标签和 AS 地址表容量 MAX_CONTEXTS 配置为 64，默认配置仍为 16。

OS1 WS 的连续 slice 在唯一 tmp 中融合；OS1 A4 AS 每 Context 只有一个 slice，均可旁路 Psum。当前 AS 仍采用 phase→Context 顺序，因此 OS1 A8/A16 的 AS64 需要 64 项融合历史，超过 16 深度，作为预期容量错误验证。OS2 WS8/AS8 使用 8 项 Psum，容量合法。

正向共 184 例：OS1 WS64 为 56 例，OS1 A4 AS64 为 16 例，OS2 WS8/AS8 各 56 例；覆盖 UINT/INT、随机/交替极值及有无 Command 空拍。另有 10 个 A8/A16 AS64 负向 case，要求在首个 Command 接受时准确捕获 CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded，禁止先进入越界计算。

```text
python RTL/cluster/tb/py/run_sram_regression.py --full
python RTL/cluster/tb/py/run_sram_regression.py --context-stress
```

VCS 从 vcs-rtl 编译时可传 `PARAMETERS="-pvalue+tb_Cluster.MAX_CONTEXTS=64"`，然后以 `PVALUE=+CONTEXT_STRESS_TEST` 选择正向专项。容量负向专项使用 +CONTEXT_CAPACITY_TEST、+CAPACITY_PRECISION=1/3/4/5/6 和 +CAPACITY_SIGN=0/1；完整自动判定由上述 Python 入口执行。Psum 默认 16 保持不变。

## 同包输入与发射重叠

规则与公式见 [Cluster 输入重叠说明](Cluster_Input_Overlap.md)。`cluster_scoreboards.svh` 逐沿检查当前Plane及地址就绪条件；`run_case` 强制覆盖多slice采样/发射重叠、连续AS地址/发射重叠、有空拍时等待地址，以及首命令后一拍发射。`+INPUT_OVERLAP_TEST` 专项168例由 `--full` 自动执行，也可用 `--input-overlap` 单独追加运行。Python `buffer_schedule.py` 和 README 生成器共用更新后的无空拍公式。
