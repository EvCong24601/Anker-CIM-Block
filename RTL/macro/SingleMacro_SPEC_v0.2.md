# 单个 Macro RTL 规格 V0.2

日期：2026-10-14。状态：V0.2 SystemVerilog RTL 已实现并通过单周期功能回归；`SYNTHESIS` 分支编译/展开通过。工艺 SRAM/ICG 适配、逻辑综合、门级仿真和 STA 尚未完成，目标频率尚未签核。

本规格面向方案 A：Macro 每次计算一个 activation digit Phase 的四路局部和，Cluster 先做跨 Macro 归约，再做 A8/A16 Activation Fusion、跨 K Tile 的 Psum 和 Requant。

**本版核心要求：读权重与全部 Macro 本地计算共一拍。** 请求在上升沿 n 采样，四路 Phase Sum 在 n+1 上升沿后的寄存器更新完成后可见，Phase II=1。仅设置入口和出口两个计算寄存边界；512-bit ACT 只保留一组入口寄存器，由四个 OC 共用。SRAM/Hold 选择、子乘法、Weight Fusion 和五层本地归约在两边界之间组合完成。

本规格定义当前 Macro 的接口、数值解释、计算时序、权重 Hold 和集成约束。


## 1 边界与规模

| 项目 | 规定 | 来源 |
|---|---|---|
| 每 Macro OC | 4 路，OC0…OC3 | 原 Block SPEC |
| Weight SRAM | 256 行 × 1024 bit，每 Macro 32 KiB | 原 Block SPEC |
| 每 OC 每行 | 256 bit，即 32 B | 原 Block SPEC |
| K_row | W2=128；W4=64；W8=32 | 原 Block SPEC |
| 计算资源 | 每 OC 128 个 2×4 子乘法器，共 512 个/Macro | 用户拆分方案与原规模推导 |
| Phase 计算次数 | A4=1；A8=2；A16=4，不等于严格周期数 | 用户指定 |
| 结果 | 每次 Phase 四路 signed18，共 72 bit | 方案 A 与原宽度链 |
| 输入 ACT | Cluster 选好 Slot，固定 512 bit，按 W 模式使用低位有效部分 | 本轮设计决定 |
| ACT 寄存 | 一组 512-bit 入口寄存器，四个 OC 共用；无第二组 ACT 对齐寄存器 | V0.2 用户确认 |
| 计算时序 | 包含 SRAM 读取的固定一拍；n 采样、n+1 结果可见；Phase II=1 | V0.2 用户确认 |
| 执行协议 | ren 发射，无 ready，计算区间不可停顿 | 旧接口与 V0.2 用户确认 |
| Fusion | Activation Fusion 在 Cluster；Weight digit Fusion 在 Macro | 用户指定方案 A |

Macro 不包含 ACT Plane Buffer、reduce_split_mask 解码、跨 Macro 归约、Activation Fusion Context、Psum、Requant、全局调度或 M/K/OC 地址生成。`os_cnt/ws_cnt/as_cnt`、`flush_reduce` 和逻辑 Context ID 不进入 Macro IO。

Cluster 的 `macro_en_mask[m]=0` 时，对该 Macro 不发射计算，即驱动其 `cim_ren=0`；因此单 Macro 不另加 macro_en 输入。停止新发射不能中断已接受请求的计算、输出寄存或输出 valid 清除。

## 2 时钟 复位与门控

**沿用旧 Macro：** 时钟 `clock` 上升沿触发；`reset` 为高有效异步复位，时序形式为 `always_ff @(posedge clock or posedge reset)`。

复位立即清除入口 valid、出口 valid、输出数据/OC mask/phase、入口 ACT 和控制寄存器，并清除 Weight Hold 的有效位。Hold 数据本体可以不复位，但不能在 hold_valid=0 时被有效复用；本版不存在乘积或归约中间数据寄存器。有效事务的全部组合运算输入必须有定义。

**沿用旧存储行为：** reset 不清除 SRAM 单元。SRAM 目标行是否已经加载由上游保证，不设置 256 个行有效位。reset 后首次计算必须 `cim_station=1`，重新建立有效权重读出；即使 SRAM 保留了内容，也不能直接使用复位前的 Hold。

**本轮设计决定：** 若 reset 打断尚未提交完成的整行写，该行内容不提供保证，使用前须重写整行；不承诺对中断写进行回滚。已经完成提交且未受电源状态变化影响的行不因逻辑 reset 主动清零。

**本轮设计决定：** 复位释放由集成端同步到 clock 并满足恢复/移除时序；复位期间禁止计算和写入。复位取消所有在途 Macro 事务，Cluster 同步取消对应标签、结果等待和预留额度，不能把复位前的 Context 与复位后的结果匹配。

门控沿用旧设计的安全方式：ICG 或低电平锁存使能后门控，不能将任意组合控制直接 AND 到时钟。reset 的异步有效不依赖门控时钟；已接受请求所需的结果/Hold 捕获边沿和最后一次输出 valid 清除边沿必须保留。

采用整个 Macro 共用门控时钟时，门控活动条件可按以下逻辑定义；该条件必须先经 ICG 或低电平锁存，不能直接生成时钟：

```text
write_active = cim_wen && !(&cim_wmask)
clock_active = !reset && (issue || write_active || in_valid || out_valid)
```

in_valid 为入口请求寄存器的有效状态，out_valid 为出口寄存器的有效状态。最后请求在 n 发射、n+1 输出后，仍须保留 n+2 边沿，使 out_valid 能变为 0。更细粒度门控可以采用等效逻辑，但不能改变功能边沿。

## 3 端口定义

本节定义 Macro 端口及其语义。所有计算控制都绑定当前成功发射的事务，不在后续周期直接使用外部当前值解释先前数据。

| 端口 | 方向 | 位宽 | 规定 | 来源 |
|---|---|---:|---|---|
| clock | 输入 | 1 | 上升沿时钟 | 旧 Macro |
| reset | 输入 | 1 | 高有效异步复位 | 用户要求沿用旧 Macro |
| cim_ren | 输入 | 1 | 发射一个 Phase 请求；每个有效上升沿可发射一笔 | 旧接口，本轮明确事务语义 |
| cim_idata | 输入 | 512 | 当前 Slot 的 4-bit digit 向量 | 固定位宽沿用旧接口；布局由本轮决定 |
| cim_raddr | 输入 | 8 | 本 Macro 的权重行地址，不自动递增 | 用户指定 |
| cim_station | 输入 | 1 | 1=刷新权重读出；0=复用已保持的原始权重行 | 旧控制极性；保持内容由本轮明确 |
| cim_oc_mask | 输入 | 4 | bit c=1 表示当前事务的 OC c 有效 | 用户指定宽度；bit 映射由本轮决定 |
| cim_precision | 输入 | 3 | W/A 精度编码，见第 4 节 | 原 Block SPEC |
| cim_signed_en | 输入 | 1 | 0 UINT×UINT；1 INT×INT | 原 Block SPEC |
| cim_phase | 输入 | 2 | 当前 activation digit 编号，低位 digit 从 0 开始 | 本轮设计决定 |
| cim_wen | 输入 | 1 | 行写请求，由 cim_wmask 按 OC 屏蔽，无 ready 或完成回执 | 常规 SRAM 扩展 |
| cim_waddr | 输入 | 8 | 写入的本地权重行地址 | 深度推导 |
| cim_wdata | 输入 | 1024 | 四路 OC 的整行原始权重，见第 5 节 | 128 B 数据布局 |
| cim_wmask | 输入 | 4 | bit c=1 屏蔽 OC c 的 32 B，0 允许写入；全行写入时使用 0000 | 常规 SRAM 扩展 |
| sram_ren | 输入 | 1 | 常规原始权重读使能，与计算/写入互斥 | 常规 SRAM 扩展 |
| sram_raddr | 输入 | 8 | 常规读的共享行号 | 常规 SRAM 扩展 |
| sram_rdata | 输出 | 1024 | 常规读的完整原始权重行；参考模型禁读时为零 | 常规 SRAM 扩展 |
| cim_odata | 输出 | 72 | 四路 signed18 Phase Sum，OC0 在最低 18 bit | 原宽度链；packing 由本轮决定 |
| cim_odata_valid | 输出 | 1 | 当前周期有结果事务；与前一采样沿的合法 issue 对应 | 旧接口与 V0.2 时序 |
| cim_odata_oc_mask | 输出 | 4 | 当前结果事务的 OC 有效位 | 本轮设计决定 |
| cim_odata_phase | 输出 | 2 | 当前结果对应的 cim_phase | 本轮设计决定 |

提供按 OC 的写 mask 和原始 SRAM 读出扩展；不提供 `ready/busy`、写完成、Context ID 或错误报告端口。Compute/Write 均为上游保证条件下的请求接口，不表示无条件允许任意读写组合。

单 Macro 不接收 macro_id。物理编号由 Cluster 的实例连接确定：

```text
Macro m 的 cim_raddr  = weight_cim_raddr，八个 Macro 共享同一个 8-bit 行号
Macro m 的 cim_oc_mask = macro_oc_mask[4*m +: 4]
```

32-bit Cluster OC mask 的上述低位优先映射是**本轮设计决定**；bit0 对应 Macro0.OC0，bit31 对应 Macro7.OC3。

## 4 精度 Phase 与符号

| cim_precision | 模式 | bW | Phase 数 | 合法 cim_phase |
|---:|---|---:|---:|---|
| 0 | W2A4 | 2 | 1 | 0 |
| 1 | W2A8 | 2 | 2 | 0、1 |
| 2 | W4A4 | 4 | 1 | 0 |
| 3 | W4A8 | 4 | 2 | 0、1 |
| 4 | W4A16 | 4 | 4 | 0、1、2、3 |
| 5 | W8A8 | 8 | 2 | 0、1 |
| 6 | W8A16 | 8 | 4 | 0、1、2、3 |
| 7 | 保留 | — | — | 非法 |

UINT 模式下所有 digit 为 unsigned。INT 模式下，只有完整整数的最高 digit 按 signed 解释：

- W2：每个独立权重为 signed2。
- W4：低 2 bit 为 unsigned2，高 2 bit 为 signed2。
- W8：四个 2-bit digit 中前三个 unsigned2，最高一个 signed2。
- A4：唯一 digit 为 signed4。
- A8：p0 unsigned4，p1 signed4。
- A16：p0/p1/p2 unsigned4，p3 signed4。

上述符号规则来自整数补码的数值分解；不采用旧浮点尾数的全 signed nibble 编码。

Phase 的执行顺序由 Cluster 管理。**本轮集成决定：** A16 的 OS/WS 沿用 Context 内顺序，扩展为 Ctx0.p0→p1→p2→p3；AS 扩展为所有 Context 的 p0→所有 Context 的 p1→p2→p3。Macro 不计数、不配对、不自动递增 phase，对每次发射独立计算，因此不同 Context 的 Phase 可以交叠。

每个逻辑 Context 的对应 Phase 必须引用相同的逻辑 Weight、K/OC 映射及配置，这由 Cluster 保证。Cluster 仍遵守原 Block SPEC 中 Tile 级 precision/模式/计数切换须先排空的约束。

## 5 Weight 与 Activation 布局

### 5.1 整行权重

**本轮设计决定：** 外部整行写布局采用 OC、K 低位优先，写入和逻辑读出使用相同排列，无旧设计的 case/index 元数据：

```text
row[256*c + bW*j +: bW] = W[c,j]
```

OC0 位于 `[255:0]`，OC1 `[511:256]`，OC2 `[767:512]`，OC3 `[1023:768]`。物理 bitcell 可以重排，但存储适配层必须恢复该逻辑布局。

`cim_oc_mask` 仅控制计算，不控制写入。一次合法 `cim_wen` 更新全部 1024 bit，包括当前未启用的 OC。

### 5.2 选定 Slot 的 ACT

**本轮设计决定：** Cluster 使用 `act_slot_sel[m]` 选好当前 Plane 的切片，并放入 cim_idata 的低位，未使用高位补零：

| W 模式 | K_row | 合法 Slot | cim_idata 有效范围 |
|---|---:|---|---|
| W2 | 128 | 0…1 | `[511:0]` |
| W4 | 64 | 0…3 | `[255:0]`，高 256 bit 为 0 |
| W8 | 32 | 0…7 | `[127:0]`，高 384 bit 为 0 |

```text
K_start = act_slot_sel[m] * K_row
cim_idata[4*j +: 4] = Plane[4*(K_start+j) +: 4]
```

Macro 不接收 act_slot_sel，也不保存整个 Plane。四个 OC 共用 cim_idata。无效 K 的贡献由上游补零；Macro 不另加 K mask。未使用高位不得影响结果。

## 6 子乘法器与本地归约

每 OC 组织为 32 个 slice；slice s 使用该 OC 权重行的一个 byte：

```text
B = row[256*c + 8*s +: 8]，s=0…31
d[t] = B[2*t +: 2]，t=0…3
```

每个 slice 含四个 2×4 子乘法器。

| 模式 | 子乘法器的 ACT 连接 | Slice 输出 |
|---|---|---|
| W2 | 子乘法器 t 使用 ACT[4*s+t] | sum_t(d[t]*ACT[4*s+t]) |
| W4 | t0/t1 共用 ACT[2*s]，t2/t3 共用 ACT[2*s+1] | d0*a0 + 4*d1*a0 + d2*a1 + 4*d3*a1 |
| W8 | 四个子乘法器共用 ACT[s] | d0*a + 4*d1*a + 16*d2*a + 64*d3*a |

INT W4 时 d1/d3 为 signed2；INT W8 时只有 d3 为 signed2；INT W2 时四个 d 都为独立 signed2。activation digit 的 signed/unsigned 解释见第 4 节。

四种 signed/unsigned 子乘法组合的精确结果统一表示为 signed7。unsigned2×unsigned4 最大为 45。移位前先扩宽，禁止在窄表达式中移位后才进行扩宽。

Slice 输出统一扩为 signed13，再经过五层组合归约。下述箭头表示加法层级和扩宽关系，不是寄存器或时钟周期：

```text
32×signed13 → 16×signed14 → 8×signed15 → 4×signed16 → 2×signed17 → 1×signed18
```

子乘积、Slice Sum 和五层归约的中间节点全部为组合信号，不设置乘积寄存、Slice 寄存或层间流水寄存。四个 OC 并行计算；只在共同入口采样 ACT/控制，在出口寄存四路结果。

最终数学结果：

```text
S[c,p] = sum_(j=0..K_row-1)(W[c,j] * ACT_digit[j,p])
cim_odata[18*c +: 18] = signed18(S[c,p])
```

无效 OC 的对应 18-bit 数据输出为 0，输出 mask 位为 0。其余 OC 的结果不受屏蔽影响。

不执行 saturation、rounding、requant 或 activation Phase 左移。A16 仍输出单个 4-bit digit 的局部和。最大正向 Phase Sum 是 UINT W8 的 `32*255*15=122400`，signed18 足够；其他合法模式也在此统一范围内。

## 7 计算请求与结果协议

**沿用旧接口：** 不提供 ready，结果也不能由下游暂停。**V0.2 用户确认：** 使用固定一拍计算区间；Cluster 不设输出反压，结果写回即发布，Macro 结果总是被及时接收。

合法计算事务的发射条件为：

```text
issue = !reset && cim_ren && (|cim_oc_mask)
```

上游在采样上升沿前满足所有输入 setup/hold。每个上升沿的 issue 是独立事务；连续保持 cim_ren=1 表示连续发射，不表示等待同一事务完成。

`cim_oc_mask=0` 不发射事务、不刷新 Hold、不产生属于该输入的新结果；Cluster 不等待该 Macro。cim_ren=0 时计算控制输入被忽略。无新发射时，先前已接受请求仍在其 n+1 边沿完成输出及可能的 Hold 刷新，不能被当前 mask=0 或 cim_ren=0 取消。

每笔合法 issue 恰好对应 n+1 的一个结果，顺序不变。没有输入时，下一拍出口 valid 为 0；不能清除或重复已有事务。结果有效时数据、phase 和 OC mask 对应同一入口请求。逐边沿定义为：

```text
in_valid[n]  = issue[n]
out_valid[n] = in_valid[n-1] = issue[n-1]   // 未发生取消事务的 reset
```

等式中的状态为相应上升沿更新后的值。出口数据/标签在该边沿更新前的 in_valid=1 时捕获，否则保持。入口 valid 每个运行边沿更新，入口数据/控制仅在 issue=1 时更新。

`cim_odata_valid=0` 时输出数据、phase、OC mask 保持最近一次结果的值；这些值没有新的事务意义。连续 valid=1 的每个周期表示一笔结果，不要求 valid 中间回到 0。

### 7.1 下游接收

Cluster不设输出反压：内部每OC raw写回时置位raw_valid，经组合Requant在下一沿锁存INT8并发布requant_valid_o。raw仅供内部计算和TB观察，正式结果由Requant端口输出。若未来下游引入反压，须由 Cluster 停止新发射并继续接收已接受的 Macro 结果；不得把 ready 接到 Macro 时钟使能上，也不得仅停止 cim_ren 后就忽略下一拍的结果。Macro 不含可停顿队列。

### 7.2 外部标签

Context、K Tile、group/tree 配置等由 Cluster 在 issue 时采样，并与 Macro 的一拍结果可见时序对齐。若 Cluster 本身另有入口/出口寄存级，那些寄存级的延迟另行核算，标签按当前一拍 Macro 结果时序对齐。Macro 只回传 phase 和 OC mask，不含 Context ID 位宽参数。

Cluster 标签 valid 必须使用相同的 issue 条件，含 mask=0 的气泡；不能只按当前 cim_ren 或当前映射解释结果。不同 Macro 的 idle 位不参加归约有效性等待。

## 8 Weight Hold

**cim_station 极性：** 1 表示本次读取当前地址并刷新 Hold；0 表示关闭本次阵列读取，使用保持的权重。

**Hold 状态：** Hold 保存完整的 1024-bit 原始权重行，另保存 8-bit 行地址和 hold_valid。Hold 与 activation、precision、OC mask 无关，不保存被 activation 门控后的值，也不删除无效 OC 的权重。

**V0.2 对齐规则：** station=1 请求在 n 发射后，在 n 到 n+1 区间使用本次 SRAM 读出直接计算；在 n+1 捕获该请求的结果，并建立该行的有效 Hold。Hold 不作为当前请求的一整拍权重对齐寄存级，当前运算不能等待 n+1 更新后的 Hold 才开始。

- station=1：对应事务使用本次读取的新行；在结果捕获边沿完成逻辑 Hold 刷新。
- station=0：对应事务使用最新先行刷新请求建立的 Hold；cim_raddr 必须等于 Hold 行地址。
- station=0 可以在先行 station=1 的下一上升沿发射，无需插气泡；在新请求的组合计算区间使用同边沿已建立的有效 Hold。
- station=0 不限制 precision/signed_en 的本地解码，完整原始权重行仍按当前请求解析；Cluster 的 Tile 级配置切换约束继续有效。
- reset 或任意一次有效写入（cim_wen && !(&cim_wmask)）均清除 hold_valid；全屏蔽写入不清除。写后首次计算必须 station=1。
- 重复 station=1 允许每拍读取不同地址；地址不自动递增。

没有自动地址命中判断或隐式 SRAM 刷新。station=0 时地址不匹配或 Hold 无效属于上游非法请求，不能默默读取另一个地址或复用旧行。

### 8.1 相邻刷新与复用

| 时间 | 已有请求的动作 | 同时允许的新请求 |
|---|---|---|
| n | 接受 A：station=1、Row5 | — |
| n 到 n+1 | 使用 Row5 新读出完成 A 的组合计算 | — |
| n+1 | 输出 A；建立 Row5 的 Hold | 接受 B：station=0、Row5 |
| n+1 到 n+2 | 使用已建立的 Row5 Hold 计算 B | — |
| n+2 | 输出 B | 可以接受下一请求 |

n+1 的结果/Hold 捕获使用边沿前稳定的 A 的地址、ACT 和控制；B 的入口寄存更新发生在边沿后，不得污染 A。相邻复用的合法性判断必须考虑同边沿完成的先行刷新，不能因边沿前 hold_valid 尚未建立而误拒绝 B。

允许采用 SRAM 读出锁存器承载原始权重保持状态，也允许采用独立保持寄存器，但必须满足上述逻辑提交与相邻复用契约。物理承载方式不能增加当前请求的计算周期或引入第二组 ACT 寄存器。

## 9 行写入与常规读写互斥

每次提供完整 1024-bit 行数据，cim_wmask 按四个 32 B OC 区域屏蔽：1 保持、0 写入，0000 全写，1111 全保持。cim_wen/cim_waddr/cim_wdata 无 ready 或完成回执。常规读使用 sram_ren/sram_raddr/sram_rdata，与 CIM 计算共享存储读路径；参考模型为使能组合读，禁读或复位时读输出为零。物理 SRAM 的读回延迟待集成冻结，当前实现不承诺并发双端口能力。

**本轮设计决定：** 基线按 SRAM 单访问资源设计，权重加载和计算分阶段；不要求物理 SRAM 支持双端口或同地址 read-during-write。

- 合法写入只发生在 Macro 入口请求已经完成计算之后，且当拍 cim_ren=0。
- 若最后一次 issue 在上升沿 n，n+1 输出其结果，最早在 n+2 发射写入。n+1 仍是该请求的结果/Hold 捕获边沿，禁止在此边沿同时写入。
- 相邻上升沿允许连续整行写。每次写地址和数据在对应上升沿被采样，整行须在下一上升沿前完成提交。
- 最后一次写入在上升沿 w，最早在 w+1 发射 station=1 的计算；SRAM 适配层保证其看到已提交的新内容。
- 有效写入使 Hold 无效，屏蔽的 OC 与其他行保持；全屏蔽写、常规读不使 Hold 无效；reset 不清除 SRAM。

旧 bitcell 的高电平写窗口可以实现上述逻辑提交契约；使用其他 SRAM 时必须由适配层保证契约，不把旧 latch/bitcell 的电气行为直接当成新 IP 的能力。

同时读写、请求尚未完成就写、首次读未初始化行等不属于合法使用。仿真与形式验证需检查这些协议条件，不增加错误 IO。非法请求的数值和输出不提供正确性保证；不得把本规则理解为静默仲裁或自动重试。

写入许可按采样边沿前的状态判断：reset=0、cim_wen=1、cim_ren=0 且 in_valid=0。该时刻 out_valid=1 可以是上一边沿已经计算完成的结果，允许下游采样该独立出口寄存器，同时写 SRAM；不能误将 out_valid=1 当成仍在进行 SRAM/运算访问。

完整切换示例：最后请求 n → n+1 结果可见 → n+2 整行写 → n+3 首次 station=1 读计算 → n+4 新结果可见。

## 10 单周期计算时序

**V0.2 用户确认：** 仅设置入口 R_in 和出口 R_out 两个计算寄存边界。读权重和全部本地计算在 R_in→R_out 的同一个时钟周期内完成，不另给 SRAM 读取分配一拍。请求采样到结果寄存可见的 Phase Latency=1，合法 Phase II=1。

```text
入口 R_in（n）
  ├ ACT 与控制 ──────────────────────┐
  └ 行地址 → SRAM 读出/Hold 选择 ────┤
                                    ↓
                        2×4 子乘法与符号处理
                                    ↓
                        W2/W4/W8 权重位权重组
                                    ↓
                          五层组合本地归约
                                    ↓
                    出口 R_out（n+1）：四路结果/标签
```

| 位置 | 时间 | 行为 |
|---|---|---|
| R_in | 上升沿 n | 采样一组 ACT、地址、station、precision、signed_en、phase、mask 和入口 valid |
| 组合区间 | n 到 n+1 | SRAM 读取或 Hold 选择、512 个 2×4 子乘法器、Slice 重组、四路五层归约 |
| R_out | 上升沿 n+1 | 捕获四路 signed18、phase、OC mask 和出口 valid；刷新请求同时建立 Hold |

### 10.1 寄存器边界

- ACT 仅保存一组 512-bit 入口值，四个 OC 共用；不增加每 OC 的独立 ACT 副本。
- 计算寄存边界为 R_in 和 R_out；SRAM/Hold 选择、乘法、Slice Fusion 和本地归约位于两者之间。
- Weight Hold、SRAM 单元和物理读出锁存属于存储/复用状态，不等同于额外计算流水级；不能借这些状态增加输出 Latency。
- 入口控制可以寄存原始字段或等价的 precision/符号解码。组合计算只使用本次入口快照，不能使用实时外部控制重新解释已有请求。
- 输出数据、mask 和 phase 在入口 valid=1 的完成边沿更新；否则保持最近一次结果，出口 valid 仍按第 7 节更新。

### 10.2 连续发射与边沿

请求 A 在 n 采样、n+1 输出；请求 B 可在 n+1 同时采样、n+2 输出。n+1 捕获 A 时使用更新前的 A 的输入状态，新 B 在边沿后开始组合计算。所有精度和刷新/复用路径都遵守相同一拍 Latency。

n+1 的 NBA 更新完成后结果可见，下游上升沿寄存器在 n+2 采样该可见结果。该下游寄存边界不计入 Macro Latency；Cluster 标签应与 R_out 后的 valid/data 同周期出现。

入口数据可以在 issue=0 时保持以降低翻转，入口 valid 不得保持为 1；不允许因无新请求而让上一结果重复输出或让最后一个出口 valid 停留为 1。

### 10.3 A4 A8 A16 的计算次数

每个逻辑任务仍需 1/2/4 次 Phase 计算。连续无停顿且同一 Context 的 Phase 相邻时：

| A 精度 | 请求采样边沿 | Macro Phase 结果可见边沿 |
|---|---|---|
| A4 | p0：n | p0：n+1 |
| A8 | p0：n；p1：n+1 | p0：n+1；p1：n+2 |
| A16 | p0…p3：n…n+3 | p0…p3：n+1…n+4 |

上述为 Macro 局部 Phase 结果，不是 Cluster 完整 Fusion/Psum/Requant 的完成时间。AS 等调度可以交叠 Context，或在 Phase 间插气泡；每次已发射 Phase 的 Macro Latency 仍固定一拍，完整 Context 的经过周期取决于调度和 Phase 间隔。

### 10.4 SRAM 和时序预算

64/128/256 MHz 继续作为目标频点；256 MHz 的周期为 3.90625 ns。一拍约束必须覆盖入口 clock-to-Q、地址译码与 SRAM 读访问、Hold/精度选择、子乘法及符号处理、Weight Fusion、本地归约、连线、出口 setup 和时钟不确定性。

```text
Tclk >= Tcq_in + Tread_select + Tmul_sign + Tweight_fusion
        + Treduce + Twire + Tsetup_out + Tuncertainty
```

该式为功能时序预算表达，实际以所有合法模式、路径和 PVT 条件的 STA 为准，不能以此代替签核。四个 OC 并行，五层加法树是组合层级，不是五个周期。

除最大路径延迟外，还须检查入口更新、SRAM/Hold 状态变化到出口及 Hold 捕获端的最小路径和 hold 约束，尤其是同边沿完成旧请求并接受新请求的情况。

SRAM 适配层必须保证：地址在 n 后由入口寄存器给出，本次读出的正确原始权重在 n+1 出口 setup 之前足够早地稳定，使完整计算能被捕获。若采用高电平透明/低电平保持的读出锁存结构，还必须满足该读出窗口本身的时序。仅在 n+1 上升沿后才给出本次权重的同步读接口，不满足本版当前边沿契约。

不承诺已经达到目标频率。如果实际 SRAM 或运算路径不满足，应提供具体时序瓶颈，再讨论架构或频点；实现不得自行恢复八拍、加入额外 ACT/权重对齐级或使用变长等待。

## 11 合法性与验证要求

上游应保证合法 precision/phase、已初始化的权重、正确的 Hold 地址与有效性、读写阶段互斥及足够结果接收额度。Macro 不配对不同 Phase，也不检测上游是否重复或遗漏一个 Context 的 Phase。

建议用独立整型点积作为 golden，检查以下实现要求：

1. 七种精度的 INT/UINT；全零、极值、正负混合；W2 的独立 ACT 路由。
2. 所有合法 Phase，尤其 INT 最高 digit 与低 digit 的不同符号解释。
3. OC mask 的 16 种取值，屏蔽 OC 为 0；全零 mask 不发射。
4. 行地址、precision、phase、mask 连续每拍变化时，结果与标签不串拍。
5. 连续刷新、紧邻刷新后的复用、同一行不同 activation/OC mask 的 Hold；任意写与 reset 后 Hold 无效。
6. 整行写的 OC/K packing、连续写、写后首读，以及排空后加载。
7. 固定一拍结果可见、输入气泡、连续有效、复位中断未完成事务。
8. 刷新请求的完成与下一拍复用请求同边沿发生；零 mask 或停止发射不得取消先前请求的结果/Hold 提交。
9. 最后请求 n 后 n+1 禁止写入、n+2 允许写入；连续写及写后 w+1 首读。
10. 空闲门控下的异步复位，以及最后结果 n+1 之后 n+2 边沿正常清除出口 valid。

当前测试台为 `RTL/macro/tb/tb_SingleMacro.sv`，使用完整 W2/W4/W8 整数点积 golden，以及独立固定为一拍的 scoreboard。

VCS 的 `macro_gate0`、`macro_gate1` 分别验证门控关闭和开启状态。15 个 `macro_negative_*` case 检查 precision/phase、无效 Hold、未初始化 OC 的刷新与复用、地址不匹配、未知输入、同拍读写、流水排空前写入，以及写入/复位后的非法复用。case 目录和运行方法见 [VCS 使用说明](../../vcs-rtl/README.md)。

`SYNTHESIS` 分支编译/展开通过，仅证明该源代码分支可编译和展开，不代表完成逻辑综合。当前使用通用 SRAM 与功能 ICG 模型，未进行工艺 IP 适配、门级仿真、STA 或形式验证，未生成代码/功能覆盖率报告。Cluster 结果发布、外部 Context 标签对齐和 A8/A16 最终 Fusion 仍须在 Cluster 集成中验证；Macro 回归检查停止新发射后已接受请求继续输出的行为。

## 12 设计约定

- reset 为高有效异步复位，SRAM 内容保持，Hold-valid 清零。
- cim_oc_mask 控制计算 OC，cim_wmask 控制每个 32 B 通道的写入，两者语义独立。
- 计算路径为 R_in→组合运算→R_out；ACT 入口为四个 OC 共用的一组 512-bit 寄存器。
- Macro 使用显式 phase 输入，回传 phase 和 OC mask；Context 与 tree 标签由 Cluster 管理。
- Hold 保存原始权重行、地址和 valid，在结果完成边沿建立，支持相邻请求复用。
- 计算、常规读和写入分阶段使用同一存储；最后计算请求 n 后最早 n+2 写入。
- 数据采用 OC/K/ACT/结果低位优先 packing。计算 mask 为0时不发射，屏蔽 OC 的结果为0。
- 门控必须覆盖有效结果输出及后续 valid 清除；Macro 不包含下游反压接口。

## 13 集成与物理实现边界

本规格已为单 Macro 的正常逻辑行为给出可实现基线。仍由相应模块规格负责的事项包括：Cluster 结果缓冲深度及信用实现、A16 Fusion 存储、Psum 溢出策略、Requant 参数和 LSM 输出协议。

Cluster 归约树及其后级可以具有自身流水，但这些延迟不改变 Macro 的一拍接口契约。功能实现位于 `RTL/macro/rtl/`，接口采用 R_in→R_out 一拍数据通路。

尤其 UINT W8A16、K=256 的全组结果为 4,278,124,800，Cluster Fusion 必须先使用足够宽度形成结果，再执行 signed32 Psum 范围检查；不能因 Macro 的 Phase Sum 仅为 signed18 而忽略最终范围。

SRAM Dual-Rail、Retention、供电/隔离/测试控制和 MAC 是否采用 MTCMOS 属于物理 IP 与电源集成接口。本逻辑 Macro 端口不含未定义的电源控制信号。时钟门控行为与物理电源域切换分别验证。实际 memory/power wrapper 必须另有物理契约并接受签核。

## 14 RTL 接口声明基线

以下声明用于统一端口，不包含 RTL 功能实现：

计算端口和 precision 编码见本节；常规 SRAM 接口包含写掩码和原始读口，外部实例须显式连接；接口的结果延迟、标签对齐和写入排空时刻按 V0.2 解释。

```systemverilog
module SingleMacro (
    input  logic          clock,
    input  logic          reset,
    input  logic          cim_ren,
    input  logic [511:0]  cim_idata,
    input  logic [7:0]    cim_raddr,
    input  logic          cim_station,
    input  logic [3:0]    cim_oc_mask,
    input  logic [2:0]    cim_precision,
    input  logic          cim_signed_en,
    input  logic [1:0]    cim_phase,
    input  logic          cim_wen,
    input  logic [7:0]    cim_waddr,
    input  logic [1023:0] cim_wdata,
    input  logic [3:0]    cim_wmask,
    input  logic          sram_ren,
    input  logic [7:0]    sram_raddr,
    output wire [1023:0]  sram_rdata,
    output logic [71:0]   cim_odata,
    output logic          cim_odata_valid,
    output logic [3:0]    cim_odata_oc_mask,
    output logic [1:0]    cim_odata_phase
);
```

每个 18-bit 输出切片单独按补码解释；不能把整个 72-bit 向量解释为一个 signed72 数。
