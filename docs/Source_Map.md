# RTL 辅助文件索引

[返回项目入口](../README.md)。功能 RTL、TB 顶层和 `vcs-rtl/` 文件在首页逐项列出；这里列出其余源码和辅助文件。路径相对仓库根目录。

## Cluster TB 共用文件

以下路径相对 `RTL/cluster/tb/`。`.svh` 由 TB include，不单独编译。

| 文件 | 用途 |
|---|---|
| `ClusterGemmOs1Ws32.sv` | OS1/WS32 W8A16 共用矩阵驱动与检查主体 |
| `ClusterGemmOs2As4.sv` | OS2/AS4 与 OS1/AS8 W8A16 共用驱动与检查主体 |
| `ClusterGemmScenario.sv` | W2/W4 高组、尾块、舍入饱和场景的共用主体 |
| `latency_audit.sv` | 观察 Command、内部发射和 raw 完成，输出时延 CSV |
| `filelist.f` | 从本 TB 目录运行时的源码清单 |
| `README.md` | TB 配置、缓存深度及量化检查约定 |
| `include/cluster_reference.svh` | 随机输入、精度边界、独立归约分组及 lane 时延模型 |
| `include/cluster_driver.svh` | Command / ACT 驱动、SRAM 权重加载和读回 |
| `include/cluster_compute_cases.svh` | 生成计算场景、点积 golden、等待输出及排空 |
| `include/cluster_scoreboards.svh` | ACT、tmp/Psum、raw 数值与时序检查 |
| `include/cluster_completion_checks.svh` | Context/lane 预留、唯一发布及批次完成检查 |
| `include/cluster_suites.svh` | 默认计算、OC、容量、Context 和输入重叠场景枚举 |
| `include/cluster_regression.svh` | initial 入口、plusarg 分派、CSV 和 watchdog |
| `include/cluster_requant_cases.svh` | 量化参考、参数映射、输出延迟、复位和边界测试 |
| `include/cluster_context_buffer_cases.svh` | AS 固定参数槽位、A4 地址旁路、参数接收与发射重叠 |
| `include/cluster_empty_batch_cases.svh` | 空批次转有效批次的输出和门控检查 |
| `include/cluster_sram_cases.svh` | SRAM 镜像、写掩码、地址隔离、读写及冲突场景 |
| `include/cluster_sram_response_cases.svh` | 同步读响应 valid 及请求 Macro 锁存检查 |
| `include/cluster_gate_checks.svh` | 实际门控时钟脉冲、关闭后的数据保持检查 |
| `include/cluster_gate_equivalence.svh` | 门控与旁路 Cluster 逐拍对照 |
| `include/cluster_gemm_driver.svh` | WS32 GEMM 权重加载与输入驱动 |
| `include/cluster_gemm_scoreboard.svh` | WS32 GEMM raw、量化输出和矩阵检查 |
| `include/cluster_gemm_regression.svh` | WS32 GEMM 场景入口与结果导出 |
| `include/cluster_gemm_as_driver.svh` | AS4/AS8 GEMM 输入、Context 参数及负向驱动 |
| `include/cluster_gemm_as_scoreboard.svh` | AS GEMM 数值、时序和输出矩阵检查 |
| `include/cluster_gemm_as_gates.svh` | AS GEMM buffer 门控、保持和 Command 切换检查 |
| `include/cluster_gemm_as_regression.svh` | AS GEMM 正负向场景入口 |
| `include/cluster_gemm_scenario_driver.svh` | 高组、尾块、舍入饱和场景的向量加载与驱动 |
| `include/cluster_gemm_scenario_scoreboard.svh` | 场景 GEMM 数值、输出 lane 和矩阵检查 |
| `include/cluster_gemm_scenario_regression.svh` | 场景 GEMM 配置、运行与输出导出 |
| `include/requant_tb_helpers.svh` | TB 共用量化函数及 per-tensor 逐 channel ZP 修正 |

## Python 工具

以下路径相对 `RTL/cluster/tb/py/`，VCS 日常运行由 `vcs-rtl/cases.py` 调用所需生成器。

| 文件 | 用途 |
|---|---|
| `buffer_schedule.py` | 调度序列、周期公式、标准表及 trace 检查 |
| `generate_readme.py` | 生成 `docs/Cluster_Timing_Tables.md` 的 42 组逐拍表及 split 编码 |
| `audit_latency.py` | 比对采集的时延 CSV 与调度公式 |
| `verify_manifest.py` | 检查默认回归的 split / precision 覆盖清单 |
| `svfiles.py` | 解析共用 `.f` 清单及 include 目录，供本地工具复用 |
| `run_sram_regression.py` | 在本地源码快照中运行 SRAM、协议与功能回归 |
| `requant_vectors.py` | 生成整数 Requant 及四通道映射 golden 向量 |
| `gemm_os1_ws32_w8a16_vectors.py` | WS32 矩阵量化、输入/权重向量及结果检查 |
| `gemm_os2_as4_w8a16_vectors.py` | OS2/AS4 矩阵、Context 参数向量及结果检查 |
| `gemm_os1_ws1_as8_w8a16_vectors.py` | OS1/AS8 矩阵、门控切换向量及结果检查 |
| `gemm_scenario_vectors.py` | W2/W4 高组、N6 尾块、舍入饱和向量与结果检查 |

## Macro TB 与说明文件

以下路径相对 `RTL/macro/`。

| 文件 | 用途 |
|---|---|
| `README.md` | Macro 结构、编译与集成约定 |
| `SingleMacro_SPEC_v0.2.md` | 单 Macro 端口、精度和时序规格 |
| `tb/filelist.f` | 从 Macro 目录运行的 TB 编译清单 |
| `tb/include/macro_reference.svh` | 精度、乘加和 Slice 融合参考模型 |
| `tb/include/macro_driver.svh` | 权重写入、计算输入和复位驱动 |
| `tb/include/macro_scoreboard.svh` | Macro 输出数值、时序及门控检查 |
| `tb/include/macro_negative_cases.svh` | 非法精度、未初始化读、Hold 及读写冲突测试 |
| `tb/include/macro_regression.svh` | 正负向 case 分派和回归入口 |

`RTL/cluster/README.md` 说明 Cluster 接口、编译路径及集成约定。

## 数据与历史产物

这些目录按用途归类，同类数据无需逐个展开即可定位；实际单次 VCS 运行产物在 `vcs-rtl/work/<CASE>/`。

| 路径 / 文件模式 | 用途 |
|---|---|
| `RTL/cluster/tb/data/split_cases*.csv` | 默认、稀疏等归约配置覆盖记录 |
| `RTL/cluster/tb/data/latency_audit.csv` | 已记录的 Command / 发射 / raw 时延 |
| `RTL/cluster/tb/data/buffer_*.csv`、`external_inputs.csv` | 缓存操作、周期与外部输入记录 |
| `RTL/cluster/tb/data/gemm_*/` | 对应矩阵用例的数据集，场景类在 `gemm_scenarios/` 下 |
| 数据集中的 `x_*`、`w_*`、`weight_rows.hex`、`act_planes.hex` | 实数/量化矩阵、SRAM 权重布局和 ACT 输入 Plane |
| 数据集中的 `requant_*`、`*_config.txt`、`gemm_metadata.json` | scale / shift / ZP、运行配置和矩阵元数据 |
| 数据集中的 `*golden*`、`*reference*`、`ideal_quant.hex` | raw、CIM、ZP 修正后输出及算法参考值 |
| 数据集中的 `*schedule.csv`、`weight_layout.csv`、`channel_map.txt` | 输入周期、权重地址及逻辑/物理通道映射 |
| 数据集中的 `gemm_observed_*.csv` | TB 采集的输出事件及矩阵，供 Python 逐项比较 |
| 数据集及 `log/` 中的 `*.sha256` | 对应源码或向量的校验摘要 |
| `RTL/cluster/tb/log/*.log`、`*.csv` | 已保存的回归、审计与专项验证记录；不代表当前提交重新跑过 |
