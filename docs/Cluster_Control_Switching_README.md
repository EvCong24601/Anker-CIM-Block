# Cluster 总体控制切换与 bubble 说明

本文按当前 M1 RTL 说明 `cluster_ctrl_t` 的任务切换规则、无 bubble 条件、需排空的 case，以及理想供数条件下的等待拍数。适用场景为每个任务只使用一种有效归约宽度，允许部分组关闭；现有混合宽度配置的兼容边界也在文中单独说明。

- [控制接口与 precision 编码](#control-interface)
- [累加模式与计数切换](#accumulation-modes)
- [实际归约路径类别](#path-classes)
- [无 bubble 交接条件](#no-bubble)
- [case 切换与 bubble 详细表](#switch-cases)
- [排空拍数与计算方式](#bubble-timing)
- [验证用例与复现](#verification)

源码依据：[控制类型](../RTL/cluster/rtl/cluster_pkg.sv)、[类别与兼容函数](../RTL/cluster/rtl/cluster_func.sv)、[接收及在途检查](../RTL/cluster/rtl/cluster_top.sv)、[归约端点](../RTL/cluster/rtl/ClusterReduceTree.sv)。输出及数据布局见 [raw Psum 接口契约](Cluster_Raw_Output.md)。

<a id="control-interface"></a>
## 1. 控制接口与 precision 编码

外部 `cluster_ctrl_t` 共 102 bit，每个任务在 `reset_n=1` 且 `cmd_valid_i && cmd_ready_o` 的上升沿握手一次。这里的切换指相邻任务之间的切换，不是在一个已接收任务内部直接改写生效配置。未握手时，发送端须保持 valid 和对应 payload 稳定。

| ctrl_pkg 字段 | 位宽 | 含义 | 切换规则摘要 |
|---|---:|---|---|
| `cim_os_cnt` | 9 | 一个任务的 OS Tile 数 | 模式不变时可改变 |
| `cim_ws_cnt` | 9 | WS 的 ACT/Context 数 | 模式不变且容量合法时可改变 |
| `cim_as_cnt` | 9 | AS 的权重/Context 数 | 模式不变且容量合法时可改变 |
| `cim_reduce_split_mask` | 7 | 固定二叉树的分组/端点配置 | 同实际路径类别可跨 split 交接 |
| `cim_macro_en_mask` | 8 | Macro 计算使能 | 可变化，含关闭、全零和恢复 |
| `cim_macro_oc_mask` | 32 | 每 Macro 的 4 个 OC 及归约贡献控制 | 可变化，含稀疏、全零和恢复 |
| `cim_act_slot_sel` | 24 | 每 Macro 的 3 bit ACT slot | 可变化，须满足槽号及同组不重复约束 |
| `cim_precision` | 3 | W/A 精度组合编码 | 同 A 位宽内允许改变 W 位宽 |
| `cim_signed_en` | 1 | 权重和 ACT 的符号解释 | 可变化，随请求在 Macro 内锁存 |

上述“可变化”均以第 4 节的完整兼容检查为前提，不能只看单个字段。

### 1.1 `cim_precision[2:0]` 完整编码

W 表示权重位宽，A 表示激活位宽。编码值本身不是位宽，也不是 phase 编号。

| 十进制编码 | SystemVerilog 值 | W 位宽 | A 位宽 | ACT phase 数 | `last_phase` |
|---:|---|---:|---:|---:|---:|
| 0 | `3'd0`，W2A4 | 2 | 4 | 1 | 0 |
| 1 | `3'd1`，W2A8 | 2 | 8 | 2 | 1 |
| 2 | `3'd2`，W4A4 | 4 | 4 | 1 | 0 |
| 3 | `3'd3`，W4A8 | 4 | 8 | 2 | 1 |
| 4 | `3'd4`，W4A16 | 4 | 16 | 4 | 3 |
| 5 | `3'd5`，W8A8 | 8 | 8 | 2 | 1 |
| 6 | `3'd6`，W8A16 | 8 | 16 | 4 | 3 |
| 7 | `3'd7` | — | — | — | 非法编码 |

因此，同 A 位宽的切换集合为：A4 的 `0/2`、A8 的 `1/3/5`、A16 的 `4/6`。例如 `0→2` 是 W2A4→W4A4，只改变 W 位宽，不改变 A 位宽；其他兼容条件满足时无须因该编码变化而排空。W 改变后，新任务的 ACT slot 合法范围仍须按新 W 精度配置。

<a id="accumulation-modes"></a>
## 2. 累加模式与计数切换

下文 OS、WS、AS 分别代表 `cim_os_cnt`、`cim_ws_cnt`、`cim_as_cnt`。模式由计数推导，不是新增接口信号。

| 模式 | 条件 | 允许同时改变的计数 | 示例 `(OS, WS, AS)` |
|---|---|---|---|
| TMP | `OS=1`、`AS=1`，WS 为合法正数 | WS，包括 `1↔>1` | `(1,1,1)→(1,8,1)` |
| OS Psum | `OS>1`、`AS=1`，WS 为合法正数 | OS、WS；OS 必须始终大于 1 | `(2,1,1)→(5,8,1)` |
| AS Psum | `AS>1`、`WS=1`，OS 为合法正数 | AS、OS；AS 必须始终大于 1，OS 可跨 `1↔>1` | `(2,1,8)→(1,1,2)` |

表中各模式内部的计数变化可以和 mask、slot、符号、同 A 位宽的 W 精度变化一起发生；仍须通过路径及全部在途事务检查。模式之间切换时，有不兼容旧事务在途就需要等待。

### 2.1 合法性与容量

- OS/WS/AS 均为 1～511；不能为 0。
- WS 和 AS 不能同时大于 1。
- WS/AS 不得超过 `MAX_CONTEXTS`。
- AS 不得超过 `OUTPUT_BUFFER_DEPTH`。
- 多 phase AS 还须满足 `WGT_RADDR_BUFFER_DEPTH` 的地址容量。
- `OS>1` 时，WS 不得超过 Psum 的 `OUTPUT_BUFFER_DEPTH`。
- 每个启用 Macro 的 slot 必须处于当前 W 的合法范围；同一归约组内启用 Macro 的 K slot 不得重复。
- split 须满足当前 canonical 编码规则。

默认 `OUTPUT_BUFFER_DEPTH=16`、`WGT_RADDR_BUFFER_DEPTH=16`、`MAX_CONTEXTS=64`。例如 TMP 模式可使用 WS=64，但默认深度下 OS Psum 模式不能使用 WS=64。非法配置是协议/容量错误，等待排空不能使其合法。

<a id="path-classes"></a>
## 3. 实际归约路径类别

先由 split 确定每组的结构跨度，再由 enable/OC mask 筛选有最终有效贡献的组。新的跨 split 快速交接要求一个非空任务的有效组只有一种归约宽度，未使用的组可关闭。

| 有效归约宽度 | 典型 canonical split | 完整分组示例 | 实际路径类别 | issue 到 tmp 写入 |
|---|---|---|---|---|
| Reduce-1 | `7'h7f` | `[1,1,1,1,1,1,1,1]` | 类 0 | 3 拍 |
| Reduce-2 | `7'h07` | `[2,2,2,2]` | 类 0 | 3 拍 |
| Reduce-4 | `7'h01` | `[4,4]` | 类 1 | 4 拍 |
| Reduce-8 | `7'h00` | `[8]` | 类 2 | 5 拍 |

单 Macro 直接送入 tmp；两 Macro 经组合加法器后送入同一拍的 tmp。两路端点从 forwarding DFF 前取结果，因此 Reduce-1 和 Reduce-2 不相差一个寄存级。继续做四路、八路归约时才经过额外 forwarding 寄存器。

关闭组不会改变其他组的类别：`[2,2,2,2]→[2,2,2,0]` 仍是类 0，`[4,4]→[4,0]` 仍是类 1。其中 0 由 enable/OC mask 表示该组无有效结果。

不同 raw split 也可属于同一类。例如 `7'h01` 中启用四路组，与 `7'h05` 中仅启用左侧四路组，均为类 1；后者右侧两路组须全部关闭。组编号和 lane 布局仍按各自完整 split 解释，不能压缩或借用新任务的映射。

归约宽度不是 enable mask 的 popcount。一个结构为四路的组，即使只启用其中一个 Macro，也仍沿四路端点的寄存路径运行，属于类 1。Reduce-8 的非空 canonical split 为 `7'h00`，不存在另一个不同 canonical split 的非空 Reduce-8；该类别仍允许 mask、符号及模式内计数等兼容变化。

<a id="no-bubble"></a>
## 4. 无 bubble 交接条件

定义旧任务最后一次 issue 沿为 N。无 bubble 指新任务第一次 issue 在 N+1，而不是要求不同任务的最终输出在每一拍都连续。

兼容任务最早在旧任务最后一次 issue 的同一沿接收新 cmd。要在 N+1 issue，新任务首组权重地址和 ACT 必须在该沿可供计算使用，既可预先接收，也可在 N+1 按通道规则直通。

对新命令与当前输入任务、每级实际在途事务、待写回的 Psum tmp 事务，均执行以下兼容条件：

```text
A 位宽相同
且累加模式相同
且下列路由条件至少满足一项：
  1. raw split 完全相同，保留原有 mask 兼容规则；
  2. 其中一个任务没有任何有效输出；
  3. 两个非空任务各自只有一种有效归约宽度，且实际路径类别相同。
```

因此，完整 51 bit 配置仍随事务逐级传递，但不要求其全部 bit 相同。符号、slot、同 A 位宽的 W 精度、模式内计数及合法 mask 均可变化。

原有同 split 的 mask 兼容方式继续保留，包括结构上存在不同深度、通过 mask 选择不同组的既有场景；它不能绕过更早、不同 split 的不兼容事务。混合有效归约宽度不启用新的跨 split 快速规则。

### 4.1 为什么必须检查所有在途事务

一个全空 mask 任务可以不产生下游结果，但不能清掉前面旧任务的类别。例如：

```text
旧 Reduce-8 → 空任务 → 新 Reduce-1
```

新 Reduce-1 与最新空任务可以满足两两兼容，但若更早的 Reduce-8 仍在途，新 Reduce-1 仍须等待。相反，Reduce-2→空任务→Reduce-1 在相同 A 位宽、相同累加模式且无其他不兼容事务时，可以保持连续 issue。

关闭某条路径也不能将旧事务隐藏：占用判断使用各级自己保存的 split、mask、valid 和累加模式，不使用新任务的 mask 代替旧配置。

<a id="switch-cases"></a>
## 5. case 切换与 bubble 详细表

下表中的“可无 bubble”均要求合法配置、新命令和操作数及时到达，并兼容全部实际在途事务。“需等待”只在不兼容旧事务尚未完成时成立；已经排空则可直接接收。

| Case | 变化/示例 | 当前处理与 bubble 结论 | 关键条件或原因 |
|---|---|---|---|
| C01 | `cim_precision: 0↔2`，W2A4↔W4A4 | 可无 bubble | A 始终为 4 bit |
| C02 | `cim_precision: 1/3/5` 之间切换 | 可无 bubble | A 始终为 8 bit，W 可为 2/4/8 bit |
| C03 | `cim_precision: 4↔6`，W4A16↔W8A16 | 可无 bubble | A 始终为 16 bit |
| C04 | `cim_signed_en: 0↔1` | 可无 bubble | Macro 锁存每笔请求的符号，检查器使用旧事务来源 |
| C05 | 改变 `cim_act_slot_sel` | 可无 bubble | 新槽号合法，启用 Macro 在同一归约组内不重复 K slot |
| C06 | enable mask 开关部分 Macro/组 | 可无 bubble | 各级保留自己的使能；仍检查全部在途兼容性 |
| C07 | OC mask 稀疏、全零、恢复，或与 enable 同时变化 | 可无 bubble | 全空任务仍消费约定的输入，不借用下一任务的有效 mask |
| C08 | TMP：`(OS,WS,AS)=(1,1,1)→(1,8,1)` | 可无 bubble | OS=AS=1，WS 在容量内变化 |
| C09 | OS Psum：`(2,1,1)→(5,8,1)` | 可无 bubble | OS、WS 同时变化，OS 始终 >1，AS=1 |
| C10 | AS Psum：`(2,1,8)→(1,1,2)` | 可无 bubble | AS、OS 同时变化，AS 始终 >1，WS=1 |
| C11 | Reduce-1 `7'h7f` ↔ Reduce-2 `7'h07` | 可无 bubble | 两者均为类 0，tmp 延迟均为 3 拍 |
| C12 | `7'h01` 的四路组 ↔ `7'h05` 中仅开启四路组 | 可无 bubble | 有效组均为 Reduce-4；其他宽度的组关闭 |
| C13 | `[2,2,2,2]→[2,2,2,0]`，或 `[4,4]→[4,0]` | 可无 bubble | 关闭组不改变剩余有效组的路径类别 |
| C14 | raw split 相同，mask 改变所选择的有效组 | 保留原兼容规则，可无 bubble | 不要求因 mask 变化导致的类别变化一律排空，但仍须兼容更早的全部在途事务 |
| C15 | 同类非空任务 → 空任务 → 同类非空任务 | 可无 bubble | 空任务不占有效端点，且没有更早不兼容事务 |
| C16 | raw split 改变，Reduce-1/2 ↔ Reduce-4 | 有不兼容旧结果时需等待 | 非空任务跨类 0/1，可能出现追尾或共享资源冲突 |
| C17 | raw split 改变，Reduce-1/2 ↔ Reduce-8 | 有不兼容旧结果时需等待 | 非空任务跨类 0/2，须检查更早事务而非只看最后一笔 |
| C18 | raw split 改变，Reduce-4 ↔ Reduce-8 | 有不兼容旧结果时需等待 | 非空任务跨类 1/2 |
| C19 | A4、A8、A16 之间切换，如 `0→1` | 有不兼容旧结果时需等待 | phase 数及最后 phase 的解释改变 |
| C20 | TMP ↔ OS Psum，如 AS=1 时 OS 从 1 变为 2 | 有不兼容旧结果时需等待 | tmp/Psum 历史与发布方式改变 |
| C21 | TMP/OS Psum ↔ AS Psum | 有不兼容旧结果时需等待 | phase/Context 遍历与融合、累加方式改变 |
| C22 | 旧 Reduce-8 → 不同 split 的空任务 → 新 Reduce-1 | 新 Reduce-1 仍须等待旧 Reduce-8 | 空任务不能成为绕过旧类别保护的入口 |
| C23 | 两个非空任务为混合有效归约宽度，且 raw split 不同 | 不走跨 split 快速规则，必要时等待 | 超出单宽度快速交接的使用约束；旧的同 split 规则仍保留 |
| C24 | 新命令呈现太晚 | 出现供给空拍 | 属于命令供给等待，不是兼容判断要求排空 |
| C25 | 当前所需 ACT 或权重地址迟到 | 暂停 issue，在途结果继续完成 | 属于操作数供给等待；不能通过放宽配置比较消除 |
| C26 | 流水已经排空，再切换任意合法配置 | 无额外排空等待 | 新任务仍需完成命令及操作数接收 |
| C27 | count=0、WS/AS 同时 >1、超容量、非法 precision/split/slot | 拒绝命令 | 是协议/容量错误，不是等待几拍即可执行的 case |

对于 C16～C18，当前策略不区分深→浅和浅→深，统一保护不兼容在途事务。浅→深未必发生同拍写口冲突，但目前没有单独开放这种方向性的进一步优化。输出之间有间隔也不等于输入 II 必须大于 1。

<a id="bubble-timing"></a>
## 6. 排空拍数与计算方式

### 6.1 统一口径

若旧任务末次 issue 为 N，新任务首次 issue 为 F，则二者之间的 issue 空拍数为：

```text
bubble_count = F - N - 1
```

兼容且供数及时：新 cmd 可在 N 握手，新任务在 N+1 issue，所以 bubble_count=0。指令握手、内部 issue、raw valid 发布和接收端采样是不同事件，不应将它们混为同一拍。

### 6.2 单个旧非空任务的理想排空表

以下是当前调度的推导拍点，适用于：只有该旧任务需要排空，旧任务只有一种有效归约宽度；最后 issue 为 N；新任务不兼容并已提前呈现 cmd；两个新首操作数可在新 cmd 握手沿接收。D 为旧任务从 issue 到 tmp 的延迟。

| 旧路径类别 | 旧累加模式 | D | 旧最终结果发布沿后 | 接收端采样旧结果/最早接收新 cmd | 新任务最早 issue | issue 空拍数 |
|---|---|---:|---|---|---|---:|
| Reduce-1/2 | TMP | 3 | N+3 | N+4 | N+5 | 4 |
| Reduce-4 | TMP | 4 | N+4 | N+5 | N+6 | 5 |
| Reduce-8 | TMP | 5 | N+5 | N+6 | N+7 | 6 |
| Reduce-1/2 | OS Psum / AS Psum | 3 | N+4 | N+5 | N+6 | 5 |
| Reduce-4 | OS Psum / AS Psum | 4 | N+5 | N+6 | N+7 | 6 |
| Reduce-8 | OS Psum / AS Psum | 5 | N+6 | N+7 | N+8 | 7 |

TMP 在 tmp 捕获最终值后发布；Psum 路径再晚一拍完成写回并发布。同步接收端在 valid 发布后的下一个上升沿采样；该沿可同时接收新 cmd，但新任务首 issue 在其后一沿。

这不是任何切换都会固定插入 4～7 拍的承诺。若旧任务为空、已排空、已有若干拍结果完成，或只有部分旧事务不兼容，等待由当时实际占用决定；若 cmd/ACT/地址迟到，还会产生额外供给空拍。多个任务重叠时，要看所有不兼容旧事务的最晚结果采样沿，不能仅使用最新任务的路径类别套表。

### 6.3 为什么深→浅要保护

以 Reduce-4 切到 Reduce-2、两者都写同一 lane 为例：

```text
旧 Reduce-4 在 N issue       → N+4 写 tmp
新 Reduce-2 若在 N+1 issue   → N+4 写 tmp
```

两笔结果同拍争用同一 tmp 写口。因此，当前实现保护不兼容的在途事务，而不是仅因 raw split 的 bit 发生变化就固定停顿。

<a id="verification"></a>
## 7. 验证用例与复现

| 回归 case | 主要覆盖 |
|---|---|
| `pipeline_config` | 414 对 precision/符号/slot/兼容计数切换，WS64→1、AS8→2，逐级配置与 Context 时钟 |
| `mask_pipeline` | 567 对 enable/OC 切换，单独全零、恢复、组合变化和隐藏旧深路径的场景 |
| `path_class` | 1,092 对同类交接、21 条三任务链；单有效宽度、部分组关闭、同类跨 split 及空任务屏障 |
| `channels` | 三通道独立握手、旧末 beat 与新 cmd 同沿、缺操作数时排出旧结果、最早合法接收与 issue |
| `empty_batch` / `gate_equiv_empty_batch` | 空有效任务与后续非空任务、门控开关对照 |
| `cluster_default` / `reduce_tree` / `gate_equiv_*` | 基础算术、归约树、门控与元数据保持 |

ModelSim 无工艺库的定向功能回归，从仓库根目录运行：

```sh
python RTL/cluster/tb/py/run_sram_regression.py --csa-golden \
  --case pipeline_config --case mask_pipeline --case path_class --case channels
```

完整回归：

```sh
python RTL/cluster/tb/py/run_sram_regression.py --csa-golden --full \
  --sim-dir ../cluster_tb_work/local_sim/path_class_20261117_full
```

VCS 入口从 `vcs-rtl/` 运行，例如 `make run CASE=path_class`；实际固定 CSA 的展开/仿真需要相应工艺单元模型。当前本地验证使用 ModelSim。

2026-11-17 已完成 117/117 项 ModelSim golden 回归，包括 35 项正常用例和 82 项预期拒绝。`path_class` 的 2,247 个任务、39,564 个有效 signed32 输出全部匹配。固定 CSA 的功能及 `SYNTHESIS` 分支源码编译通过；未执行固定 CSA 门级仿真、逻辑综合或 STA。详细结果见 [路径类别验证记录](Cluster_Raw_Output.md)。

快照位于仓库外 `../cluster_tb_work/local_sim/path_class_20261117_full/`：

- `summary.log`：回归用例结果。
- `sources.json`、`validation.json`：受测源码散列及最终一致性记录。
- 各用例的 `data/channel_cycles.csv`：cmd 接收、首末 issue、末次输出采样及切换空拍。
- `data/channel_events.csv`：逐拍命令/操作数握手、issue、phase、Context 和输出有效位。
- `prior_drain`：测试参考模型为新命令计算的旧事务保护时限，覆盖所有不兼容旧任务，不仅是最近一笔。

本次 README 整理只修改文档和入口，不改变 RTL 或测试行为；第 6 节的拍数表是按当前 RTL 及采样口径推导，不能替代输入迟到、多任务重叠时的逐拍 trace。
