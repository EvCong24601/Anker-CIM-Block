# VCS RTL 仿真

在 `vcs-rtl/` 目录运行。需要 Linux 环境中的 VCS、Verdi/FSDB 支持、GNU Make 和 Python 3；Python golden 仅使用标准库。以下为 VCS 运行配置，VCS 平台的实际运行结果应以该平台日志为准。

```sh
make list
make run CASE=gemm_ws32_tensor
make run CASE=gemm_ws32_channel
make run CASE=gemm_as4_channel
make run CASE=gemm_edge_n_tail_channel
make wave CASE=gemm_edge_n_tail_channel
make gemm-regression
make regression
```

`run` 按顺序生成数据、编译、仿真、检查。全部 76 个 case 中，28 个为正向测试，48 个应命中指定 Fatal；`gemm-regression` 包含 11 个正向端到端 GEMM。`cases.py` 是配置来源；修改后执行 `python3 cases.py --write` 更新 `cases.mk`。

每个 case 使用独立的 `work/<CASE>/`，包含编译产物、`compile.log`、`sim.log`、退出状态、`data/` 和波形。重复相同 case 会更新该目录；保留多次结果时指定不同 `CASE_TAG`。

## 参数设置

- `CASE`：选择下文的预设；自动选择 TB、golden 生成器、编译参数、plusargs 和精确检查标志。
- `CASE_TAG`：结果目录及波形后缀，默认等于 CASE。建议仅使用英文、数字和下划线。
- `TB`：不指定 CASE 时可选 `cluster / macro / reduce / requant / gemm / gemm_as / gemm_edges`，用于自定义实验。指定 CASE 时由预设决定。
- `PARAMETERS`：追加 VCS 编译期覆盖，例如 `-pvalue+tb_Cluster.OUTPUT_BUFFER_DEPTH=16`。计数、容量和精度参数改变后应重新编译。
- `PVALUE`：追加运行期 plusargs，例如 `+CAPACITY_SIGN=1`；不能用于改变编译期 parameter。
- `PYTHON`：Python 命令，默认 `python3`。`WORK_DIR`：结果根目录，默认 `work`。
- `OUTPUT`：可执行文件名，默认 TB 名。`FSDB_FILE`：自定义波形路径，默认 `<TOP>_<CASE_TAG>.fsdb`。
- `VCS_FLAGS / ALL_DEFINE / LIB_LIST`：编译选项、宏和附加模型。默认打开协议断言及 `CLUSTER_FSDB`。

```sh
make run CASE=context_stress CASE_TAG=os1_as64_os2_as8
make com CASE=requant_channel
make sim CASE=requant_channel
make check CASE=requant_channel
make run CASE=gemm_edge_w4_high_channel FSDB_FILE=w4_hi_pc.fsdb
```

`com/sim/check` 必须使用相同的 CASE、CASE_TAG 和编译参数。`sim` 保留仿真退出状态，`check` 判定最终成功或失败；完整实验使用 `run`。负向测试不能只看进程退出码，检查器要求恰好一个、且匹配预期的 Fatal，其他诊断一律失败。正向 GEMM 除 SV 检查外还逐元素比较 Python golden。

## 文件列表

- `verilog_file_common.f`：包、Macro 功能模块及 Cluster 功能模块，按依赖顺序编译。
- `verilog_file_cluster.f`：主 Cluster TB 和时延观察器。
- `verilog_file_macro.f`：SingleMacro TB。
- `verilog_file_reduce.f`：归约树单元 TB。
- `verilog_file_requant.f`：组合 Requant 单元 TB。
- `verilog_file_gemm_ws32.f`：OS1/WS32，M32/K128/N16，四批 N4。
- `verilog_file_gemm_as4.f`：OS2/AS4，M32/K512/N16，逐 Context 参数表深度4。
- `verilog_file_gemm_edges.f`：W4/W2 高位置组、N尾部、舍入饱和。
- `verilog_file_pl.f`：保留的聚合入口；Makefile 使用上述独立入口。

所有 `.f` 路径相对 `vcs-rtl/`；SV include 路径分别指向两个 TB 目录。`.svh` 不单独编译。

## 波形与日志

七个 TB 均支持 `+FSDB_FILE=<路径>`。Makefile 自动传入，例如 `tb_Cluster_GEMM_OS2_AS4_gemm_as4_channel.fsdb`，后缀说明当前实验；直接运行 TB 时默认 `<TOP>_default.fsdb`。FSDB 在仿真开始时记录完整层级，同一 suite 内的各子 case 用英文 `[CASE_START] time=... description=...` 日志区分。`make wave CASE=...` 自动打开相同文件。

启用 Requant 的主 Cluster 专项自动设置 `ENABLE_REQUANT=1`；raw-only 主回归保持0。AS4默认 `ZP_DEPTH=4`，容量负向设为2。Context压力保留 Psum 深度16、地址表64与元数据64；OS1/AS64先逐Context融合旁路Psum，OS2/AS8仍使用Psum。逐通道 scale/zp 固定对应 OC c；N尾部不压缩通道参数。

## Case 说明

- `cluster_default`：Raw arithmetic and standard timing。
- `sram_rw`：Regular SRAM read write and OC masks。
- `sram_preload_conflict`：Reject regular SRAM overlap with preload；预期拒绝，匹配 `CLUSTER_SRAM_PROTOCOL: regular access overlaps preload`。
- `sram_compute_conflict`：Reject regular SRAM overlap with compute；预期拒绝，匹配 `CLUSTER_SRAM_PROTOCOL: regular access overlaps compute`。
- `macro_gate0`：SingleMacro clock gating 0。
- `macro_gate1`：SingleMacro clock gating 1。
- `macro_negative_precision`：Reject precision；预期拒绝，匹配 `SM_PROTOCOL: illegal precision/phase`。
- `macro_negative_phase`：Reject phase；预期拒绝，匹配 `SM_PROTOCOL: illegal precision/phase`。
- `macro_negative_hold_invalid`：Reject hold invalid；预期拒绝，匹配 `SM_PROTOCOL: reuse invalid hold`。
- `macro_negative_uninitialized`：Reject uninitialized；预期拒绝，匹配 `SM_PROTOCOL: read uninitialized row`。
- `macro_negative_masked_uninitialized`：Reject masked uninitialized；预期拒绝，匹配 `SM_PROTOCOL: read uninitialized row`。
- `macro_negative_masked_uninitialized_reuse`：Reject masked uninitialized reuse；预期拒绝，匹配 `SM_PROTOCOL: read uninitialized row`。
- `macro_negative_hold_address`：Reject hold address；预期拒绝，匹配 `SM_PROTOCOL: reuse address mismatch`。
- `macro_negative_hold_address_pending`：Reject hold address pending；预期拒绝，匹配 `SM_PROTOCOL: reuse address mismatch`。
- `macro_negative_unknown_write`：Reject unknown write；预期拒绝，匹配 `SM_PROTOCOL: unknown write input`。
- `macro_negative_unknown_activation`：Reject unknown activation；预期拒绝，匹配 `SM_PROTOCOL: unknown compute input`。
- `macro_negative_unknown_control`：Reject unknown control；预期拒绝，匹配 `SM_PROTOCOL: unknown compute input`。
- `macro_negative_read_write`：Reject read write；预期拒绝，匹配 `SM_PROTOCOL: simultaneous read/write`。
- `macro_negative_write_busy`：Reject write busy；预期拒绝，匹配 `SM_PROTOCOL: write before pipeline drain`。
- `macro_negative_hold_after_write`：Reject hold after write；预期拒绝，匹配 `SM_PROTOCOL: reuse invalid hold`。
- `macro_negative_hold_after_reset`：Reject hold after reset；预期拒绝，匹配 `SM_PROTOCOL: reuse invalid hold`。
- `requant_unit`：Integer quantization arithmetic and four OC mapping。
- `requant_negative_mode`：Reject Requant mode；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: per-channel scale requires conv_mode`。
- `requant_negative_shift_low`：Reject Requant shift low；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: shift must be -31..31`。
- `requant_negative_shift_high`：Reject Requant shift high；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: shift must be -31..31`。
- `requant_negative_unknown`：Reject Requant unknown；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: unknown configuration`。
- `requant_negative_channel_shift`：Reject Requant channel shift；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: shift must be -31..31`。
- `requant_negative_conv_group`：Reject Requant conv group；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: Requant requires one aligned reduction group`。
- `requant_negative_zp_group`：Reject Requant zp group；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: Requant requires one aligned reduction group`。
- `requant_integration`：requant integration。
- `requant_channel`：requant channel。
- `requant_reset`：requant reset。
- `requant_boundary`：requant boundary。
- `os_count_limit`：os count limit。
- `oc_merge`：oc merge。
- `act_buffer`：act buffer。
- `full_act`：full act。
- `mixed_context`：mixed context。
- `input_overlap`：input overlap。
- `context_stress`：context stress。
- `reduce_tree`：All reduction trees and clock gating。
- `zero_count_0`：Reject zero count field 0；预期拒绝，匹配 `CLUSTER_COUNT_RANGE: counts must be 1..255`。
- `zero_count_1`：Reject zero count field 1；预期拒绝，匹配 `CLUSTER_COUNT_RANGE: counts must be 1..255`。
- `zero_count_2`：Reject zero count field 2；预期拒绝，匹配 `CLUSTER_COUNT_RANGE: counts must be 1..255`。
- `context_capacity_p0_s0`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded`。
- `context_capacity_p0_s1`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded`。
- `context_capacity_p1_s0`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded`。
- `context_capacity_p1_s1`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded`。
- `context_capacity_p2_s0`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded`。
- `context_capacity_p2_s1`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded`。
- `context_capacity_p3_s0`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded`。
- `context_capacity_p3_s1`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded`。
- `context_capacity_p4_s0`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded`。
- `context_capacity_p4_s1`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded`。
- `context_capacity_p5_s0`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded`。
- `context_capacity_p5_s1`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded`。
- `context_capacity_p6_s0`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded`。
- `context_capacity_p6_s1`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded`。
- `address_capacity_s0`：Reject AS64 address capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: weight address depth exceeded`。
- `address_capacity_s1`：Reject AS64 address capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: weight address depth exceeded`。
- `metadata_capacity_s0`：Reject AS64 metadata capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: context metadata exceeded`。
- `metadata_capacity_s1`：Reject AS64 metadata capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: context metadata exceeded`。
- `gemm_ws32_tensor`：W8A16 M32 K128 N16 OS1 WS32 tensor。
- `gemm_as4_tensor`：W8A16 M32 K512 N16 OS2 AS4 tensor。
- `gemm_ws32_channel`：W8A16 M32 K128 N16 OS1 WS32 channel。
- `gemm_as4_channel`：W8A16 M32 K512 N16 OS2 AS4 channel。
- `as_context_capacity`：Reject as context capacity；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: AS context zp depth exceeded`。
- `as_context_zp_reload`：Reject as context zp reload；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: AS context zp changed across K Tiles`。
- `as_context_scale_reload`：Reject as context scale reload；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: AS context scale changed across K Tiles`。
- `gemm_edge_w4_high_tensor`：w4 high tensor。
- `gemm_edge_w4_high_channel`：w4 high channel。
- `gemm_edge_w2_high_tensor`：w2 high tensor。
- `gemm_edge_w2_high_channel`：w2 high channel。
- `gemm_edge_n_tail_tensor`：n tail tensor。
- `gemm_edge_n_tail_channel`：n tail channel。
- `gemm_edge_boundaries_channel`：boundaries channel。
