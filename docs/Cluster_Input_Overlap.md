# Cluster 同包输入与发射重叠

本说明对应当前 RTL。一个包包含一份 ACT，以及使用该 ACT 的权重地址命令：WS/单 Context 每 Context 一包，AS 每 Tile 一包。当前包内，后续 ACT Plane 和 AS 地址接收可以与已有输入的计算发射重叠。下一包仍在当前包末次发射后的下一拍才接受，不使用同拍覆盖 bank 的协议。

## 发射条件与暂停

输入在时钟上升沿寄存，不能在同一个接受沿直接发射。当前包有效、当前 Plane 的 `act_slice_valid[phase]` 有效、当前 Context 地址已收到且批次尚未结束时，发射一次计算。AS 地址依序接收，故 `context_idx < command_count` 表示该地址有效。WS 的地址由包首命令提供。

若当前地址尚未到达，保持 phase、Context、Tile，不产生 Macro 读使能，不推进内部计算。之后的地址命令可以正常接受；地址寄存后的下一拍恢复发射。公共配置仍由首命令锁定，后续 AS 命令仅增加该 Context 的地址，不重装 A0。

外部协议不变：包首 Command 按 `cmd_valid_i && cmd_ready_o` 接受，随后 P−1 个 ACT Plane 连续到达，没有独立 ACT valid/ready。AS 后续地址命令可插空拍；ACT 连续采样不依赖它们。`act_complete` 仍记录加载完成状态，但不再是发射的全包屏障。

## 周期公式

令 P=A位宽/4，R=max(ws_cnt,as_cnt)，t 为 Tile，c 为 Context，p 为 Slice。C0 为首包命令与 A0 的接受沿。以下公式要求后续命令无额外空拍，所有序号从零开始。

- WS/单 Context：包起点 `S=(t*R+c)*(P+1)`；A[p] 在 `S+p` 接收，在 `S+1+p` 发射。下一包起点为 `S+P+1`。
- AS：包起点 `S=t*(1+R*P)`；Context c 地址在 `S+c` 接收，A[p] 在 `S+p` 接收，OS1 在 `S+1+c*P+p` 发射，OS>1 在 `S+1+p*R+c` 发射。下一 Tile 包起点为 `S+1+R*P`。
- 地址有空拍时，每次发射沿为“前一次发射后一拍、当前 Plane 接收后一拍、当前 Context 地址接收后一拍”三者的最晚沿；第一发射只取当前 Plane 和地址的就绪沿。
- 发射后的 Macro、归约、tmp/Psum 路径保持原有时延；标准 W2/W4/W8 路径从末次发射到 raw 分别为 3/4/5T。精确 lane 时延仍取决于归约终点。

WS 和 OS1 AS 按 Tile→Context→Slice 执行；OS>1 AS 保留 Tile→Slice→Context。OS1 AS 先在 tmp 中融合，所有 OS1 模式关闭 Psum；OS>1 AS 保留 Psum 融合历史。两种 AS 都使用同一份 64×8-bit 权重地址表，详见 [OS1 AS 融合与权重地址暂存](Cluster_AS_OS1_Fusion.md)。

## A16 单 Context 示例

- C0：接收命令、A0。
- C1：接收 A1，同时发射 A0。
- C2：接收 A2，同时发射 A1。
- C3：接收 A3，同时发射 A2。
- C4：发射 A3。
- C5：可接受下一包命令、A0；上一包结果仍可能在后级流水中。

## A16 OS>1 AS2 示例

- C0：接收 Context0 地址与 A0。
- C1：接收 Context1 地址与 A1；发射 A0/Context0。
- C2：接收 A2；发射 A0/Context1。
- C3：接收 A3；发射 A1/Context0。
- C4：发射 A1/Context1。
- C5、C6：依次发射 A2/Context0、A2/Context1。
- C7、C8：依次发射 A3/Context0、A3/Context1。
- C9：可接受下一 Tile 包。

以下仅指 OS>1；OS1 AS2 的逐 Context 示例见上述融合说明。如果 Context1 地址延迟到 C5 接受，C1 仍发射 A0/Context0，C2～C5 等待地址，C6 发射 A0/Context1，然后按原顺序继续。C2、C3 的 ACT 采样仍照常进行。

## 容量与边界

A8/A16 的合法单 Context、WS、AS case 均能重叠后续 Plane 接收和发射。A4 没有后续 Plane，但 AS 多 Context 能重叠后续地址与已有 Context 的发射。OS1/OS2 均支持；符号和权重位宽不改变输入就绪规则。

Psum 深度保持 16。OS1 WS64 合法；OS1 AS64 的 A4/A8/A16 均合法且不使用 Psum；OS2 AS64 仍作为 Psum 容量错误验证。OS2 WS8/AS8 合法。批次末次发射后仍等待全部结果发布，再接受下一批。

## 代码与验证

- `RTL/cluster/rtl/cluster_dut_adapter.sv`：按当前 Plane 和地址就绪条件发射。
- `RTL/cluster/tb/include/cluster_scoreboards.svh`：检查发射条件、就绪后无多余等待、整块 ACT bank 写入/保持、逐 digit 数据、顺序、算术和逐 lane 输出周期。
- `RTL/cluster/tb/include/cluster_compute_cases.svh`：每个计算 case 检查 C1 首发射，以及适用的 ACT/地址重叠和地址空拍等待覆盖。
- `RTL/cluster/tb/include/cluster_suites.svh`：`run_input_overlap_suite` 提供 168 例，覆盖七精度、UINT/INT、OS1/2、单 Context/WS2/AS2、有无 Command 空拍。有空拍的 AS case 特意将 Context1 地址延迟到整份 ACT 收完后，检查先发射 Context0，再暂停并恢复。
- `RTL/cluster/tb/py/buffer_schedule.py`：独立 Python 周期公式，供输入/运算 trace、时延核对和 README 示例生成使用。

从仓库根目录运行 `python RTL/cluster/tb/py/run_sram_regression.py --input-overlap`；`--full` 自动包含该专项、原回归及大 Context 容量验证。VCS 编译后可运行 `make sim PVALUE=+INPUT_OVERLAP_TEST`。

所有 case 开始日志与 display/诊断使用英文。Markdown 及 README 生成器已采用上述新周期；此前 Word 文档中的“收齐后发射”及旧公式属于历史版本，不应用于当前 RTL。
