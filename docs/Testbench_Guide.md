# Testbench 文件与检查职责

功能源码位于 `RTL/cluster/rtl/` 和 `RTL/macro/rtl/`；TB、include、golden和观察器位于对应的 `tb/`。`.svh` 在module内include，不单独编译，也不形成硬件层次。

## 顶层与观察接口

`cluster_top.sv` 是Cluster功能参考顶层，默认启用Requant。正式结果端口为 `requant_data_o[255:0]` 和 `requant_valid_o[31:0]`，最多4个物理lane有效，无下游反压。

raw Psum属于内部计算状态。RTL端口表中的 `psum_data_o/out_valid_o` 声明仅以注释说明，不是可连接端口。四个Cluster TB通过 `dut.raw_data/raw_valid` 建立同名TB别名，用于数值、时序及Psum检查；产品集成无需这些观察信号。

- `tb_Cluster.sv`：共享连接、参数和状态；raw-only suite设置ENABLE_REQUANT=0，量化专项覆盖为1。
- `tb_ClusterReduceTree.sv`：208个归约树、mask和转发ICG检查；独立消费路径模型覆盖父节点屏蔽时的子节点关钟。
- `tb_ClusterRequant.sv`：9611个整数向量与512个四通道映射向量。
- 三个GEMM TB：11个正向矩阵case与5个AS参数负向case，配置和源文件分工见 [GEMM](Cluster_GEMM.md)。

## Cluster include

- `cluster_reference.svh`：随机输入、精度边界、独立树分组、OC贡献与lane时延。
- `cluster_driver.svh`：Command握手、完整ACT流、AS地址和 `load_weight_row`；权重逐Macro通过常规WLC口写入并读回校验。
- `cluster_compute_cases.svh`：case开始日志、矩阵生成与独立点积golden、WLC加载、输入、等待输出、计数和排空。
- `cluster_scoreboards.svh`：ACT bank、tmp/Psum ICG与保持、逐phase算术历史、Command和内部raw发布。
- `cluster_requant_cases.svh`：量化golden、参数profile、固定OC索引、1T延迟、输出保持、复位与批次参数边界。
- `cluster_sram_cases.svh`：逐字节独立镜像、8×256行和16种mask、片选/地址隔离、连续访问、复位保留、写后计算和Hold刷新。
- `cluster_suites.svh`：默认计算、OC merge、ACT容量、完整ACT、混合Context和输入重叠等场景枚举。
- `cluster_regression.svh`：initial入口、plusarg分派、CSV创建/关闭、覆盖计数和watchdog。SRAM专项先于默认计算CSV分派。

`monitoring`仅限定计算检查窗口。`expected/lane_due/raw_seen`等是TB状态，不是产品硬件寄存器。golden不读取DUT权重存储来生成预期值。

`latency_audit.sv` 通过TB层次观察命令、内部发射与raw完成周期，输出 `latency_audit.csv` 供 `audit_latency.py` 核对，不属于功能RTL。

## SingleMacro include

- `macro_reference.svh`：随机输入与完整整数权重解码点积。
- `macro_driver.svh`：常规写行、Phase输入、气泡、排空、复位和case日志。
- `macro_scoreboard.svh`：逐OC写镜像、Hold历史、固定一拍结果与数据/标签保持。
- `macro_negative_cases.svh`：15类协议负向检查，必须命中指定SM_PROTOCOL诊断。
- `macro_regression.svh`：primitive穷举、256行、七精度、符号/phase/mask、极值、Hold和随机场景。

逐OC SRAM初始化检查位于RTL的仿真检查分支，受SINGLE_MACRO_ASSERTIONS控制，综合时排除。

## 采样、日志与运行

驱动在下降沿更新输入；上升沿前预测握手和运算，NBA后检查寄存器。TB中的短延迟用于避开采样竞争，不代表硬件流水。每个case输出英文 `[CASE_START] time=... ns suite=... description=...`；CMD_SEND和CMD_ACCEPT分别记录驱动时间与真正接受时间。

从 `vcs-rtl/` 执行 `make run CASE=...`，或用 `make regression` 运行134项，其中93项为预期拒绝。`requant_context`覆盖OS1/OS2、两种scale模式和串行批次之间的独立Context参数。完整变量、文件列表、精确检查规则和FSDB命名由 [VCS说明](../vcs-rtl/README.md) 统一定义。

协议与容量见 [输入时序](Cluster_Input_Overlap.md)，常规读写见 [SRAM接口](Cluster_Weight_SRAM_Interface.md)，量化参数及输出寄存规则见 [Requant](Cluster_Requant.md)。

## Context与时钟检查

`cluster_context_buffer_cases.svh`检查固定Context参数槽、七精度AS16/AS8、两种scale模式及接收未结束时已经发射。`cluster_gate_checks.svh`检查Macro三个时钟域、raw/INT8逐lane时钟，以及per-tensor关闭的三组scale寄存器保持。地址深度1的A4专项独立验证旁路；所有AS精度均有AS17容量拒绝。

常规SRAM驱动在下降沿给地址，上升沿采样后比较读回；计算Macro延迟保持1T。所有AS采用Slice→Context，OS1 A8/A16也校验Psum历史。

完整验证条件、门控开关对照及证据见[验证清单](Cluster_Verification.md)。

`cluster_gate_equivalence.svh`在CHECK_GATE_EQUIVALENCE=1时实例化全ICG旁路镜像，逐拍比较调度、Macro/归约、tmp/Psum、量化参数和raw/INT8，包含无效lane保持值。八个gate_equiv用例同时运行原有golden检查。
