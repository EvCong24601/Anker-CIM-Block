# Cluster testbench：tmp、bit fusion、Psum acc 与 ICG

参考 adapter 连接八个真实 SingleMacro RTL，输出为 raw signed32，未包含 requant。尚未综合、映射工艺库 ICG、运行 STA 或门级功耗验证。

ACT 输入只有 `act_data_i[1023:0]`，采样沿由 `cmd_fire=cmd_valid_i&&cmd_ready_o` 决定。WS/单 Context 每次接受 Command 时采样新 slice；AS 每个 phase 在 Ctx0 采样并保存，后续 Context 使用内部保存的数据，外部 ACT 不参与该拍计算。Command 停顿且需要新 ACT 时，保持 Command 和 ACT 数据至接受沿；ACT 没有独立握手信号。

## 目录与入口

```text
cluster_tb/
  sv_code/    SystemVerilog、testbench、独立时延观察器
  py/         仿真入口、split/逐拍生成器、时延检查器
  log/        回归日志与时延核对报告
  data/       split 配置、逐拍事件、实测时延 CSV
  filelist.f  相对 cluster_tb 目录的完整 SV 文件列表
  README.md
```

在本目录执行 `python py/run_regression.py --gate-unit --latency-audit --log regression_tmp_default.log`。脚本也可从仓库根目录或其他目录调用；结果固定写入本目录的 data/log，work 库和波形不提交。

## 流水与存储

归约终点 → 每 channel 的 `tmp_result` DFF → fusion/acc → tmp 状态或 Psum → 写回即按 OC 发布。channel=`4*group+OC`，并行 OC 不增加串行周期数，Context 共用组合运算逻辑。

- `os=1`：在 tmp 完成 A8/A16 融合后直接输出，Psum buffer 全部关闭；A4 直接输出，不启用 fusion 状态 DFF。
- `os>1`、WS/单 Context：相邻 phase 在 T[0] 融合当前 Tile；最高 phase 将融合结果填充到 P[ctx]，后续 Tile 与同深度旧 Psum 相加。
- `os>1`、AS：首 Tile/A0 填充 P[ctx]；后续 Tile/A0 做 P[ctx]+tmp；A1..A3 做 P[ctx]+(tmp<<(4*phase))。每个 phase 回写同一 Context，fusion 与 acc 同拍二选一。
- WS/单 Context 的 A8/A16 在后续 Tile 最后 phase 仍有 **fusion 加法器 → acc 加法器** 串联路径，中间无 DFF，需 STA。两个未使用加法器的输入均隔离为零；隔离不缩短有效串联路径。
- AS 同 Context 的 slice 间隔 n=as_cnt 个有效发射周期，Tile 间隔 n*P，P=A位宽/4；不是 n*os_cnt，且不乘 OC 数。输入停顿另计。

`PSUM_BUFFER_DEPTH=MAX_CONTEXTS` 控制 Context 状态深度，默认 16；Context 数不超过 min(MAX_CONTEXTS,PSUM_BUFFER_DEPTH)。六个标准例需要至少 2 个 Context 位置。最终输出不设 FIFO、无输出排队：每个 OC 的结果写回即发布一拍 out_valid_o[oc]，lane 数据保持到该 OC 下次发布，下游默认无反压。

首条 cmd_i 握手时锁定整批配置：os>1 仅开放 Psum 深度 0..max(ws,as)-1，高地址 entry 整批关闭；os=1 全部关闭。这里的高地址指 entry，不是每个数据的高位。A4 的 T 状态全关；A8/A16 的 WS/单 Context 只开放 T[0]，os=1 的 AS 开放低 as 个 T 深度，os>1 的 AS 用 P 保存融合历史、T 全关。

`tmp_input_cg_en` 提前 tmp 捕获 1T 寄存；`tmp_state_cg_en/psum_cg_en` 在 tmp 捕获时寄存，提前运算写回 1T。每深度/每 channel 的数据 DFF 接专用 `MacroClockGate` latch-based ICG 模型；空拍/未选 OC/未写深度关闭。整批深度掩码保持到最后 Context 的最后 lane 发布，之后关闭；下一批在该边界后接收。valid 正常推进以免旧数据被误认为新结果。ASIC 需映射工艺库 cell。

仿真参考状态用 longint 避免中间截断，最终 RAW 为 signed32，溢出时报错，不引入饱和。它仍是仿真 adapter，而非已通过综合/STA 的生产 Cluster RTL。

## Reduce tree 与时延

t1..t6 是向父级转发的 DFF。Pair 结束时从 t3..t6 前取数并关闭转发 DFF；quad 结束时从 t1/t2 前取数并关闭它们；仅继续归约时打开。`reduce_cg_en` 仍提前 1T，接 ICG。没有独立 root-only DFF 或统一末级对齐流水。

从实际 Macro 发射 Cq：叶子/pair 在 C(q+2) 捕获 tmp、C(q+3) 运算完成；quad 在 C(q+3)/C(q+4)；root 在 C(q+4)/C(q+5)。标准 W2/W4/W8 完整延迟为 **3T/4T/5T**。混合树各 channel 按自身深度写最终预留槽位并独立发布各自 lane，浅层 lane 不等深层，同 lane 按 Context 顺序发布。同批 Context 使用同一 descriptor 布局。输入停顿和 requant 不含在上述周期中。

## 六种配置与清单

case 1..6 为：`(os,ws,as)=(1,1,1)、(1,1,2)、(1,2,1)、(2,1,1)、(2,2,1)、(2,1,2)`。七种 precision 各展开六例，共 42 个操作表；INT×INT/UINT×UINT 共用时序。

运行生成器后，`data/buffer_cycle_cases.txt` 逐行列出 tmp 数据、操作、深度和写回时刻。[buffer_cycle_cases.csv](data/buffer_cycle_cases.csv) 提供完整 split/group 枚举。仓库主 README 的附录 A 按六种配置、七种精度列出 ACT 采样、权重地址、运算和结果位置。

`py/buffer_schedule.py` 从 `data/split_cases.csv` 将所有合法 split/sign 配置展开为六种配置，生成 `data/buffer_cycle_cases.csv`。默认 200×6=1200 个组合、44280 个有效 group 事件。这是无停顿逻辑时序枚举，不等于额外仿真了1200组。[buffer_operations.csv](data/buffer_operations.csv) 是实际标准仿真记录，无停顿版本核对480个运算事件：

```text
python py/buffer_schedule.py --trace data/buffer_operations.csv
```

三个 count 最小为1。ws>1/as=1为WS，as>1/ws=1为AS，二者为1则单Context，不定义同时>1。precision 0..6为W2A4、W2A8、W4A4、W4A8、W4A16、W8A8、W8A16。A0..A3为4-bit slice，INT仅最高有效slice按signed4。WS顺序为Tile→Context→phase，AS为Tile→phase→Context。

descriptor为131bit，包含共享8-bit weight_cim_raddr与32-bit macro_oc_mask。每phase提交Command，首拍同拍提供ACT/地址；AS复用Plane的计算拍也提交Command。同地址有效Hold用cim_station=0，首读/换地址/写入后刷新。标准映射：W2 slots=[0,1,0,1,0,1,0,1]/split07/EN55；W4 slots=[0,1,2,3,0,1,2,3]/split01/EN33；W8 slots=[0,1,2,3,4,5,6,7]/split00/EN0F。每组K128，ACT高512bit补零。WS地址T0=20/T1=30，AS的T0 Ctx0/1=20/21、T1=30/31，均为8-bit十六进制。

psum_data_o 输出 raw signed32（1024 bit，32 channel）；out_valid_o 每 OC 一位，写回即置位一拍；不同 Context 独立，不包含 requant。

## 验证

完整 case 分类、六种数据 pattern、各精度 split 数量和参数作用范围见 [仓库首页的 tb_Cluster 测试 case](../../../README.md#tb_cluster-测试-case)。

```text
python py/run_regression.py --gate-unit --latency-audit --log regression_tmp_default.log
python py/run_regression.py --en 81 --oc 84218421 --os 2 --psum-depth 3 --patterns 2 --log regression_tmp_sparse_depth3.log
```

默认1368个Cluster case：1200穷举数据case、84标准时序case、28 Command空拍/多Context交错case、56三Tile/三Context极值case。另有208个reduce-tree门控单元case。EN=FF时每符号合法split数为1,1,16,16,16,25,25，每组有效K严格小于256。AS 复用拍会故意改变外部 ACT，检查实际计算始终使用已保存的 Plane。

检查独立整数点积、每channel到达周期、WS tmp状态、AS逐phase Psum历史、os=1 Psum保持、未用加法器输入隔离、真实ICG时钟、关闭DFF保持、高地址深度整批关闭和按序发布。`--latency-audit` 启用 `sv_code/latency_audit.sv`，采集 [latency_audit.csv](data/latency_audit.csv) 的140个标准Context输出；`py/audit_latency.py` 按六种配置公式核对，生成 [latency_audit_validation.log](log/latency_audit_validation.log)。Python检查器只依赖标准库，无需本地Word文档。

要求 ModelSim 的 vlib/vlog/vsim 在 PATH。Python 入口按顺序编译 sv_code 中的源文件，自动定位 `../../macro/rtl`；也可用 `--macro-rtl PATH` 指定。`filelist.f` 可从本目录手动编译，仿真时选择具体顶层。`+DATA_DIR=路径` 控制 SV 的 CSV 输出位置，Python 入口自动传入绝对 data 路径；直接运行 TB 时默认当前工作目录。

OS_TILES 控制穷举 suite，范围1..14。UINT W8A16 的 ACT 限制到0..32768/os_cnt-1，使最终结果保持 signed32。验证入口对应的日志为 `log/regression_tmp_default.log`、`log/regression_tmp_default_reduce_gate.log`、`log/regression_tmp_sparse_depth3.log` 和 `log/latency_audit_validation.log`。
