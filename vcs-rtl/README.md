# VCS RTL 仿真

基于 Synopsys VCS 的 Cluster/Macro 回归入口。所有命令都在 `vcs-rtl/` 目录下运行。

**环境要求**：Linux + VCS + GNU Make + Python 3；只有看波形才需要 Verdi/FSDB。Python 只负责生成 golden 向量和比对结果，仅用标准库。

## 1. 五分钟上手

```sh
make list                                    # 列出全部 133 个 case 及一句话说明
make run CASE=gemm_os1_ws32_w8a16_tensor     # 跑一个正向用例
```

`make run` 串起四个阶段，任一阶段失败即停止：

| 阶段 | 单独执行 | 做什么 | 产物（在 `work/<CASE_TAG>/`） |
|---|---|---|---|
| 1 | `make prepare` | 生成 golden 数据和 plusarg 向量 | `data/` |
| 2 | `make com` | VCS 编译 | `compile.log`、可执行文件、`csrc/` |
| 3 | `make sim` | 跑仿真 | `sim.log`、`sim.exit`、`.fsdb` |
| 4 | `make check` | 判定通过或失败 | 终端打印 `PASS` / `FAIL:` |

每个 case 独占 `work/<CASE_TAG>/`，重跑会覆盖同一目录。要保留多次结果，换一个 `CASE_TAG`：

```sh
make run CASE=context_stress CASE_TAG=os1_as16_os2_as8
```

`cases.py` 是 case 配置的唯一来源。改完必须重新生成 `cases.mk`，否则 `make run` 会报 `Unknown CASE`：

```sh
python3 cases.py --write
```

## 2. 选一个 case

case 分两类，判定方式完全不同：

- **正向（43 个）**：退出码 0、日志含约定的 `PASS ...` 标记、无任何 Fatal/Error；GEMM 类还要逐元素对齐 Python golden。
- **负向（90 个）**：故意触发协议违规，要求日志里**恰好一条**匹配预期的 Fatal。多一条、少一条、或命中普通 Error 都算失败。

按被测对象分 10 组：

| TB | case 数 | 覆盖内容 |
|---|---|---|
| `cluster` | 98 | Cluster 顶层：默认算术、SRAM 协议、Requant、Context 容量、门控等价性 |
| `macro` | 17 | SingleMacro：2 个门控正向 + 15 种协议拒绝 |
| `gemm_os1_ws32_w8a16` | 2 | OS1/WS32，M32 K128 N16，tensor/channel 量化 |
| `gemm_os2_as4_w8a16` | 7 | OS2/AS4，M32 K512 N16，含 5 个 AS 参数负向 |
| `gemm_w4a16_high_group` | 2 | W4A16 高组场景 |
| `gemm_w2a8_high_group` | 2 | W2A8 高组场景 |
| `gemm_w4a16_n6_tail` | 2 | W4A16 N6 尾块 |
| `gemm_w4a16_round_clip` | 1 | W4A16 舍入截断（仅 channel） |
| `reduce` | 1 | 归约树与时钟门控 |
| `requant` | 1 | Requant 组合逻辑单元 |

133 条的完整清单见文末折叠块，日常查名字用 `make list` 即可。批量执行：

```sh
make gemm-regression   # 11 个正向端到端 GEMM
make regression        # 全部 133 个，负向用例按预期通过
```

## 3. 改参数

| 变量 | 作用 |
|---|---|
| `CASE` | 选预设：自动决定 TB、golden 生成器、编译参数、plusarg 和检查标志 |
| `CASE_TAG` | 结果目录名与波形后缀，默认等于 `CASE`；建议只用英文、数字、下划线 |
| `TB` | 不指定 `CASE` 时直接选裸 TB，取值见上表左列 |
| `PARAMETERS` | 追加**编译期**参数，如 `-pvalue+tb_Cluster.OUTPUT_PSUM_DEPTH=16` |
| `PVALUE` | 追加**运行期** plusarg，如 `+CAPACITY_SIGN=1`；改不了编译期 parameter |
| `PYTHON` | Python 命令，默认 `python3` |
| `WORK_DIR` | 结果根目录，默认 `work` |
| `OUTPUT` | 可执行文件名，默认 TB 名 |
| `FSDB_FILE` | 波形路径，默认 `<TOP>_<CASE_TAG>.fsdb` |
| `VCS_FLAGS` / `ALL_DEFINE` / `LIB_LIST` | 编译选项、宏、附加模型；默认打开协议断言与 `CLUSTER_FSDB` |

分步执行时 `com` / `sim` / `check` 必须用同一组 `CASE`、`CASE_TAG` 和编译参数，否则会走进别的目录或用了别的参数：

```sh
make com   CASE=requant_channel
make sim   CASE=requant_channel
make check CASE=requant_channel
make run   CASE=gemm_w4a16_high_group_channel FSDB_FILE=w4_hi_pc.fsdb
```

`sim` 只记录退出状态，`check` 才是最终裁决：指定 `CASE` 时按该 case 的规则判定；不指定 `CASE` 时退化为「`sim.exit` 为 0 + `sim.log` 含 `PASS` + 不含 fatal/Error-」。

### 深度参数怎么联动

集成时只设一个 `OUTPUT_PSUM_DEPTH`（默认 16），下面三个自动跟随：

```
OUTPUT_PSUM_DEPTH
  └─ OUTPUT_BUFFER_DEPTH
       ├─ WGT_RADDR_BUFFER_DEPTH   (权重 CIM 读地址表)
       └─ REQUANT_CONTEXT_DEPTH    (Requant Context 参数表)
```

`MAX_CONTEXTS`（默认 64）是独立的调度标签容量，不参与联动。容量负向测试会显式覆盖兼容参数，此时以显式值为准。

每个物理输出 OC 只有一套 acc 和一套 bit-fusion 算术，所有 Context 通过 Psum 索引复用；Context 深度只扩展状态存储，不复制算术单元。

`ENABLE_REQUANT=1` 打开 Requant 专项，raw-only 回归保持 0。OS1/AS 的 A8/A16 走 Psum 历史，A4 只旁路地址深表；逐通道参数与 OC 固定对应。

## 4. 文件列表（.f）

12 个 `.f` 都放在 `vcs-rtl/` 下，里面的路径也相对该目录：

| 清单 | 内容 |
|---|---|
| `verilog_file_common.f` | 包 + 6 个 Macro 功能模块 + 4 个 Cluster 功能模块，按依赖顺序 |
| `verilog_file_cluster.f` | 主 Cluster TB + 时延观察器 |
| `verilog_file_macro.f` | SingleMacro TB（自包含，不引用 common） |
| `verilog_file_reduce.f` | 归约树单元 TB |
| `verilog_file_requant.f` | Requant 组合单元 TB |
| `verilog_file_gemm_os1_ws32_w8a16.f` | OS1/WS32 TB + 共用主体，M32 K128 N16，四批 N4 |
| `verilog_file_gemm_os2_as4_w8a16.f` | OS2/AS4 TB + 共用主体，M32 K512 N16，逐 Context 参数表深度 16 |
| `verilog_file_gemm_w4a16_high_group.f` | `tb_Cluster_GEMM_W4A16_HighGroup.sv` |
| `verilog_file_gemm_w2a8_high_group.f` | `tb_Cluster_GEMM_W2A8_HighGroup.sv` |
| `verilog_file_gemm_w4a16_n6_tail.f` | `tb_Cluster_GEMM_W4A16_N6_Tail.sv` |
| `verilog_file_gemm_w4a16_round_clip.f` | `tb_Cluster_GEMM_W4A16_RoundClip.sv` |
| `verilog_file_pl.f` | 兼容用聚合入口；Makefile 不使用它 |

**加一个源文件只需改一处**：功能 RTL 进 `verilog_file_common.f`，TB 侧文件进对应的 `verilog_file_<target>.f`。Makefile 的 TB 表和 `cases.py` 的 case 表都不用动，新 TB 只要自带一个 `.f` 就会被自动识别。`.svh` 走 `+incdir+` 搜索（两个 TB 目录），不单独编译。

## 5. 波形与日志

10 个 TB 都支持 `+FSDB_FILE=<路径>`，`make run` 会自动传入：

```sh
make run  CASE=gemm_os2_as4_w8a16_channel
make wave CASE=gemm_os2_as4_w8a16_channel   # Verdi 打开同名波形
make debug CASE=gemm_os2_as4_w8a16_channel  # 打开 Verdi 数据库
make vcd   CASE=gemm_os2_as4_w8a16_channel  # 导出 VCD
```

- 默认文件名 `<TOP>_<CASE_TAG>.fsdb`，例如 `tb_Cluster_GEMM_OS2_AS4_W8A16_gemm_os2_as4_w8a16_channel.fsdb`
- 不经 Makefile 直接跑 TB 时默认 `<TOP>_default.fsdb`
- FSDB 从 0 时刻记录完整层级；一个 suite 内的多个子 case 用 `[CASE_START] time=... description=...` 分隔

## 6. GEMM 专项

11 个正向 GEMM 和 5 个 AS 参数负向的矩阵规模、地址布局、量化模式与检查目标，见 [GEMM 用例总览](../docs/Cluster_GEMM.md)。

主 Cluster 与 AS4 GEMM 的参数深度默认 16；AS4 容量负向把 `ZP_DEPTH` 覆盖为 1 和 2。`requant_buffers` 覆盖七精度固定 Context 参数的 77 个例子，`requant_a4_address_bypass` 用地址深度 1。

## 7. 完整 case 清单（133 条）

与 `make list` 同序。日常查名字用 `make list` 即可，这里作为离线备查。

<details>
<summary>展开查看全部 133 条</summary>

- `cluster_default`：Raw arithmetic and standard timing；成功标志 `PASS configurations=`。
- `sram_rw`：Regular SRAM read write and OC masks；成功标志 `PASS sram_rw`。
- `sram_write_compute_conflict`：Reject regular SRAM write during active compute；预期拒绝，匹配 `CLUSTER_SRAM_PROTOCOL: regular access overlaps compute`。
- `sram_compute_conflict`：Reject regular SRAM read with compute Command；预期拒绝，匹配 `CLUSTER_SRAM_PROTOCOL: regular access overlaps compute`。
- `macro_gate0`：SingleMacro clock gating 0；成功标志 `PASS clock_gating=`。
- `macro_gate1`：SingleMacro clock gating 1；成功标志 `PASS clock_gating=`。
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
- `requant_unit`：Integer quantization arithmetic and four OC mapping；成功标志 `PASS requant_unit`。
- `requant_negative_as17_capacity`：Reject Requant as17 capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `requant_negative_mode`：Reject Requant mode；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: per-channel scale requires conv_mode`。
- `requant_negative_unknown`：Reject Requant unknown；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: unknown configuration`。
- `requant_negative_conv_group`：Reject Requant conv group；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: Requant requires one aligned reduction group`。
- `requant_negative_zp_group`：Reject Requant zp group；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: Requant requires one aligned reduction group`。
- `requant_integration`：requant integration；成功标志 `PASS requant_integration cases=168`。
- `requant_channel`：requant channel；成功标志 `PASS requant_channel cases=1536`。
- `requant_context`：requant context；成功标志 `PASS requant_context cases=4`。
- `requant_reset`：requant reset；成功标志 `PASS requant_reset`。
- `requant_boundary`：requant boundary；成功标志 `PASS requant_boundary`。
- `os_count_limit`：os count limit；成功标志 `PASS os_count_limit cases=12`。
- `oc_merge`：oc merge；成功标志 `PASS oc_merge_leftmost cases=288`。
- `act_buffer`：act buffer；成功标志 `PASS act_buffer_capacity cases=280`。
- `full_act`：full act；成功标志 `PASS full_act_4096 cases=12`。
- `mixed_context`：mixed context；成功标志 `PASS mixed_context cases=24`。
- `input_overlap`：input overlap；成功标志 `PASS input_overlap cases=168`。
- `context_stress`：context stress；成功标志 `PASS context_stress cases=224`。
- `requant_full_shift`：Full INT10 AS Context parameters and OC gating；成功标志 `PASS context_buffers cases=77`。
- `requant_empty_batch`：Seven precisions empty batch to live batch clock hold；成功标志 `PASS empty_batch cases=7`。
- `requant_buffers`：Seven precisions AS16/AS8 fixed slots and A4 weight bypass；成功标志 `PASS context_buffers cases=77`。
- `requant_a4_address_bypass`：A4 AS16 with one weight address register；成功标志 `PASS context_buffers cases=22`。
- `as17_p0_s0_os1`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p0_s0_os2`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p0_s1_os1`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p0_s1_os2`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p1_s0_os1`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p1_s0_os2`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p1_s1_os1`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p1_s1_os2`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p2_s0_os1`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p2_s0_os2`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p2_s1_os1`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p2_s1_os2`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p3_s0_os1`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p3_s0_os2`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p3_s1_os1`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p3_s1_os2`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p4_s0_os1`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p4_s0_os2`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p4_s1_os1`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p4_s1_os2`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p5_s0_os1`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p5_s0_os2`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p5_s1_os1`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p5_s1_os2`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p6_s0_os1`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p6_s0_os2`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p6_s1_os1`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as17_p6_s1_os2`：Reject AS17 fixed-slot capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `reduce_tree`：All reduction trees and clock gating；成功标志 `PASS reduce_clock_gating cases=208`。
- `zero_count_0`：Reject zero count field 0；预期拒绝，匹配 `CLUSTER_COUNT_RANGE: counts must be 1..255`。
- `zero_count_1`：Reject zero count field 1；预期拒绝，匹配 `CLUSTER_COUNT_RANGE: counts must be 1..255`。
- `zero_count_2`：Reject zero count field 2；预期拒绝，匹配 `CLUSTER_COUNT_RANGE: counts must be 1..255`。
- `context_capacity_p0_s0`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `context_capacity_p0_s1`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `context_capacity_p1_s0`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `context_capacity_p1_s1`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `context_capacity_p2_s0`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `context_capacity_p2_s1`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `context_capacity_p3_s0`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `context_capacity_p3_s1`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `context_capacity_p4_s0`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `context_capacity_p4_s1`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `context_capacity_p5_s0`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `context_capacity_p5_s1`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `context_capacity_p6_s0`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `context_capacity_p6_s1`：Reject AS64 with OS2 and Psum depth16；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `address_capacity_s0`：Reject AS16 address capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: weight address depth exceeded`。
- `address_capacity_s1`：Reject AS16 address capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: weight address depth exceeded`。
- `metadata_capacity_s0`：Reject AS16 metadata capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: context metadata exceeded`。
- `metadata_capacity_s1`：Reject AS16 metadata capacity；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: context metadata exceeded`。
- `gemm_os1_ws32_w8a16_tensor`：W8A16 M32 K128 N16 OS1 WS32 tensor；成功标志 `PASS gemm_os1_ws32_w8a16 M=32 K=128 N=16`。
- `gemm_os2_as4_w8a16_tensor`：W8A16 M32 K512 N16 OS2 AS4 tensor；成功标志 `PASS gemm_os2_as4_w8a16 M=32 K=512 N=16`。
- `gemm_os1_ws32_w8a16_channel`：W8A16 M32 K128 N16 OS1 WS32 channel；成功标志 `PASS gemm_os1_ws32_w8a16 M=32 K=128 N=16`。
- `gemm_os2_as4_w8a16_channel`：W8A16 M32 K512 N16 OS2 AS4 channel；成功标志 `PASS gemm_os2_as4_w8a16 M=32 K=512 N=16`。
- `as_context_capacity`：Reject as context capacity；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: AS context zp depth exceeded`。
- `as_context_capacity_default`：Reject as context capacity default；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: AS context zp depth exceeded`。
- `as_context_zp_reload`：Reject as context zp reload；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: AS context zp changed across K Tiles`。
- `as_context_scale_reload`：Reject as context scale reload；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: AS context scale changed across K Tiles`。
- `as_context_tensor_scale_reload`：Reject as context tensor scale reload；预期拒绝，匹配 `CLUSTER_REQUANT_CONFIG: AS context scale changed across K Tiles`。
- `gemm_w4a16_high_group_tensor`：w4a16 high group；成功标志 `PASS gemm_w4a16_high_group`。
- `gemm_w4a16_high_group_channel`：w4a16 high group；成功标志 `PASS gemm_w4a16_high_group`。
- `gemm_w2a8_high_group_tensor`：w2a8 high group；成功标志 `PASS gemm_w2a8_high_group`。
- `gemm_w2a8_high_group_channel`：w2a8 high group；成功标志 `PASS gemm_w2a8_high_group`。
- `gemm_w4a16_n6_tail_tensor`：w4a16 n6 tail；成功标志 `PASS gemm_w4a16_n6_tail`。
- `gemm_w4a16_n6_tail_channel`：w4a16 n6 tail；成功标志 `PASS gemm_w4a16_n6_tail`。
- `gemm_w4a16_round_clip_channel`：w4a16 round clip；成功标志 `PASS gemm_w4a16_round_clip`。
- `gate_equiv_default`：Gated/ungated Cluster same-edge comparison: default；成功标志 `PASS configurations=`。
- `gate_equiv_requant_buffers`：Gated/ungated Cluster same-edge comparison: requant_buffers；成功标志 `PASS context_buffers cases=77`。
- `gate_equiv_requant_channel`：Gated/ungated Cluster same-edge comparison: requant_channel；成功标志 `PASS requant_channel cases=1536`。
- `gate_equiv_context_stress`：Gated/ungated Cluster same-edge comparison: context_stress；成功标志 `PASS context_stress cases=224`。
- `gate_equiv_input_overlap`：Gated/ungated Cluster same-edge comparison: input_overlap；成功标志 `PASS input_overlap cases=168`。
- `gate_equiv_sram`：Gated/ungated Cluster same-edge comparison: sram；成功标志 `PASS sram_rw`。
- `gate_equiv_requant_reset`：Gated/ungated Cluster same-edge comparison: requant_reset；成功标志 `PASS requant_reset`。
- `gate_equiv_requant_boundary`：Gated/ungated Cluster same-edge comparison: requant_boundary；成功标志 `PASS requant_boundary`。
- `as64_p0_s0_os1`：Reject AS64 with OS1；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as64_p0_s1_os1`：Reject AS64 with OS1；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as64_p1_s0_os1`：Reject AS64 with OS1；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as64_p1_s1_os1`：Reject AS64 with OS1；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as64_p2_s0_os1`：Reject AS64 with OS1；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as64_p2_s1_os1`：Reject AS64 with OS1；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as64_p3_s0_os1`：Reject AS64 with OS1；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as64_p3_s1_os1`：Reject AS64 with OS1；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as64_p4_s0_os1`：Reject AS64 with OS1；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as64_p4_s1_os1`：Reject AS64 with OS1；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as64_p5_s0_os1`：Reject AS64 with OS1；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as64_p5_s1_os1`：Reject AS64 with OS1；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as64_p6_s0_os1`：Reject AS64 with OS1；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `as64_p6_s1_os1`：Reject AS64 with OS1；预期拒绝，匹配 `CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth`。
- `sram_response`：Synchronous read valid and sampled Macro response；成功标志 `PASS sram_response reads=32`。
- `gate_equiv_sram_response`：Read response gated/ungated comparison；成功标志 `PASS sram_response reads=32`。

</details>

## 8. 延伸阅读

- [验证清单](../docs/Cluster_Verification.md)：逐项验证目标与覆盖矩阵
- [GEMM 用例总览](../docs/Cluster_GEMM.md)：GEMM case 的矩阵规模、地址布局、量化模式

## Per-tensor ZP外移后的数据

运行前须用`make prepare CASE=<case>`重新生成匹配的数据。GEMM TB新增读取`cim_golden.hex`，先检查CIM未加ZP的饱和INT8，再在TB按channel加ZP并饱和，比较`quant_golden.hex`。原算法保存为`original_quant_reference.hex`，差异写入metadata；per-channel仍执行原CIM内加ZP逻辑。

`as_context_zp_reload`现在明确在per-channel运行，继续验证ZP重载拒绝。per-tensor后续Tile的未使用ZP变化由Context正向测试覆盖。接口结构及容量诊断名称保持兼容。
