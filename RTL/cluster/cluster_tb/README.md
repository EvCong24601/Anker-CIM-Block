# Cluster testbench：tmp、bit fusion、Psum acc 与 ICG

参考 adapter 连接八个真实 SingleMacro RTL，输出为 raw signed32，未包含 requant。尚未综合、映射工艺库 ICG、运行 STA 或门级功耗验证。

外部 ACT 为1024-bit Plane 流：首个 i_cmd 接受沿接收A0，随后P−1个周期连续接收A1..A(P−1)，P=A位宽/4；无 ACT 握手。完整数据保存于4096-bit act_buffer，收齐后再内部按precision、counts和slot分发。

WS每个Tile/Context加载一个完整ACT并发送一次Command。AS每个Tile仅加载一次完整ACT，各Context仍各发送一次带自身权重地址的Command；后续地址命令可与ACT后续Slice重叠。内部发射等待完整ACT和全部AS地址收齐，首命令尚未接受时保持Command+A0；剩余ACT流一旦开始就逐拍接收。

Context是同一channel内独立保存、独立输出的计算任务，Psum[ctx]为其深度位置。WS的Context对应不同ACT，AS的Context对应不同权重地址；os表示每个Context累加的K Tile数。各Context不互相相加。术语、外部接收和内部发射的逐拍表见[仓库首页](../../../README.md)。

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

在本目录执行 `python py/run_regression.py --gate-unit --mixed-context --full-act --act-buffer --latency-audit --log regression_act_capacity_default.log`。脚本也可从仓库根目录或其他目录调用；入口把源码和检查脚本复制到仓库外的 cluster_tb_work/local_sim/<日志名>，work、CSV、日志和波形均在副本内生成；--sim-dir 可指定仓库外目录。该副本不提交 Git，仓库 data/log 仅保存经核对的结果。

## 流水与存储

每个OC仅一个32-bit tmp数据寄存器，以及深度 OUTPUT_BUFFER_DEPTH（默认16）的32-bit Psum Context buffer。每 OC 共用一套 fusion 和一套 acc；同一 OC 每拍仅选择一个 Context entry，其他深度保持。

WS/单 Context：归约 R_slice 与旧 tmp 做融合后写入 tmp，A0 直接覆盖；下一拍消费 tmp。os=1 最后 phase 直接输出，不写 Psum；os>1 仅最后 phase 填充或累加 Psum[ctx]。旧 tmp 的 acc 与新归约数据的 fusion 可同拍位于 tmp 两侧，属于不同输入结果。

AS：归约 R_slice 先写 tmp，下一拍首 Tile/A0 填充 Psum[ctx]，后续 Tile/A0 做 acc，高 phase 做 fusion。AS A8/A16 在 os=1 时也使用 Psum 保存各 Context 的 fusion 历史，跨 Tile acc 关闭；AS A4 os=1 直接输出。

门控：tmp_input_cg_en 提前 tmp 捕获一拍；psum_cg_en 在捕获 tmp 时预测下一拍的唯一 Context 写回。首 Command 开放低 max(ws,as) 个所需 Psum entry，高地址整批关闭；WS os=1 和 AS A4 os=1 全关。门控请求逐 OC 至多一位有效，实际 ICG 时钟与关闭 DFF 保持由 TB 检查。

同一结果的 fusion 和 acc 不串联。WS 归约末级与 fusion 在 tmp 前的路径需要 STA；AS 在 tmp 后二选一。未用组合块两个输入隔离为零。存储tmp/Psum为32 bit，组合参考计算及TB golden使用64-bit longint；当前测试输出raw signed32，未包含 requant，未做生产综合/STA/功耗签核。

## Reduce tree 与时延

t1..t6 是向父级转发的 DFF。Pair 结束时从 t3..t6 前取数并关闭转发 DFF；quad 结束时从 t1/t2 前取数并关闭它们；仅继续归约时打开。`reduce_cg_en` 仍提前 1T，接 ICG。没有独立 root-only DFF 或统一末级对齐流水。

从实际 Macro 发射 Cq：叶子/pair 在 C(q+2) 捕获 tmp、C(q+3) 运算完成；quad 在 C(q+3)/C(q+4)；root 在 C(q+4)/C(q+5)。标准 W2/W4/W8 从末内部发射到raw的延迟为 **3T/4T/5T**。混合树各 channel 按自身深度直接发布各自 lane，浅层 lane 不等深层，同 lane 按 Context 顺序发布。同批 Context 使用同一 descriptor 布局。输入停顿和 requant 不含在上述周期中。

## 六种配置与清单

case 1..6 为：`(os,ws,as)=(1,1,1)、(1,1,2)、(1,2,1)、(2,1,1)、(2,2,1)、(2,1,2)`。七种 precision 各展开六例，共 42 个操作表；INT×INT/UINT×UINT 共用时序。

运行生成器后，`data/buffer_cycle_cases.txt` 逐行列出 tmp 数据、操作、深度和写回时刻。[buffer_cycle_cases.csv](data/buffer_cycle_cases.csv) 提供完整 split/group 枚举。仓库主 README 的附录 A 按六种配置、七种精度列出 外部ACT接收、内部发射、权重地址、运算和结果位置。

`py/buffer_schedule.py` 从 `data/split_cases.csv` 将所有合法 split/sign 配置展开为六种配置，生成 `data/buffer_cycle_cases.csv`。默认 200×6=1200 个组合、44280 个有效 group 事件。这是无停顿逻辑时序枚举，不等于额外仿真了1200组。[buffer_operations.csv](data/buffer_operations.csv) 是实际标准仿真记录，无停顿版本核对480个运算事件：

```text
python py/buffer_schedule.py --trace data/buffer_operations.csv
```

三个 count 最小为1。ws>1/as=1为WS，as>1/ws=1为AS，二者为1则单Context，不定义同时>1。precision 0..6为W2A4、W2A8、W4A4、W4A8、W4A16、W8A8、W8A16。A0..A3为4-bit slice，INT仅最高有效slice按signed4。WS顺序为Tile→Context→phase，AS为Tile→phase→Context。

descriptor为131bit，包含共享8-bit weight_cim_raddr与32-bit macro_oc_mask。每Tile/Context提交一次Command；首个Context命令同拍提供A0，其他Slice连续接收；AS其余Context各提交地址命令。内部所有phase由已保存descriptor和act_buffer驱动。同地址有效Hold用cim_station=0，首读/换地址/写入后刷新。标准映射：W2 slots=[0,1,0,1,0,1,0,1]/split07/EN55；W4 slots=[0,1,2,3,0,1,2,3]/split01/EN33；W8 slots=[0,1,2,3,4,5,6,7]/split00/EN0F。每组K128，ACT高512bit补零。WS地址T0=20/T1=30，AS的T0 Ctx0/1=20/21、T1=30/31，均为8-bit十六进制。

psum_data_o 输出 raw signed32（1024 bit，32 channel）；out_valid_o 每 OC 一位，写回即置位一拍；不同 Context 独立，不包含 requant。

## 验证

完整 case 分类、六种数据 pattern、各精度 split 数量和参数作用范围见 [仓库首页的 tb_Cluster 测试 case](../../../README.md#tb_cluster-测试-case)。

```text
python py/run_regression.py --gate-unit --mixed-context --full-act --act-buffer --latency-audit --log regression_act_capacity_default.log
python py/run_regression.py --en a5 --oc 84218421 --depth 3 --full-act --mixed-context --latency-audit --log regression_act_frame_sparse_depth3.log
```

默认1368个Cluster case：1200穷举数据case、84标准时序case、28 Command空拍/多Context交错case、56三Tile/三Context极值case。另有208个reduce-tree门控单元case。EN=FF时每符号合法split数为1,1,16,16,16,25,25，每组有效K严格小于256。完整ACT加载后改变外部ACT，逐digit检查内部计算使用act_buffer。--full-act另加12个W8A16全4096-bit、八Macro root归约K256定向case。

检查独立整数点积、每channel到达周期、WS唯一tmp状态、AS（含os=1融合）的逐phase Psum历史、旁路 case 的 Psum保持、未用加法器输入隔离、真实ICG时钟、关闭DFF保持、高地址深度整批关闭和按序发布。`--latency-audit` 启用 `sv_code/latency_audit.sv`，采集 [latency_audit.csv](data/latency_audit.csv) 的140个标准Context输出；`py/audit_latency.py` 按六种配置公式核对，生成 [latency_audit_validation.log](log/latency_audit_validation.log)。Python检查器只依赖标准库，无需本地Word文档。

要求 ModelSim 的 vlib/vlog/vsim 在 PATH。Python 入口按顺序编译 sv_code 中的源文件，自动定位 `../../macro/rtl`；也可用 `--macro-rtl PATH` 指定。`filelist.f` 可从本目录手动编译，仿真时选择具体顶层。`+DATA_DIR=路径` 控制 SV 的 CSV 输出位置，Python 入口自动传入本地副本的绝对 data 路径；直接运行 TB 时默认当前工作目录。

OS_TILES 控制穷举 suite，范围1..14。UINT W8A16 的 ACT 限制到0..32768/os_cnt-1，使最终结果保持 signed32。验证入口对应的日志为 `log/regression_act_capacity_default.log`、`log/regression_act_capacity_default_reduce_gate.log`、`log/regression_act_frame_sparse_depth3.log` 和 `log/latency_audit_validation.log`。

混合 Context 定向 suite 通过 --mixed-context 启用，额外24例覆盖 W4A4/A8/A16、两种符号、os=1/2、WS/AS双 Context，以及 pair/quad 同拍发布不同 Context。内部 Context 标签按 lane 保存。FSDB 由 CLUSTER_FSDB 宏控制，VCS Makefile 开启；ModelSim 默认不开启。--depth 设置 OUTPUT_BUFFER_DEPTH，--psum-depth 为同一参数的命令行别名。

Cluster 数据 DFF 分布见[仓库首页](../../../README.md#cluster-数据-dff-位置)：ACT4096、归约中间级464、唯一tmp1024、Psum1024×OUTPUT_BUFFER_DEPTH、输出保持1024 bit；不含控制寄存器及SingleMacro内部。

外部输入实测见[external_inputs.csv](data/external_inputs.csv)，含396条标准输入事件；act_sample是日志标记，并非输入pin。所有C周期以首个外部i_cmd+A0为C0；latency_audit.csv的last_input是末内部发射，delta为内部路径3/4/5T。整批完成需另计完整ACT与地址收集时间；单bank在内部发射结束后接收下一包。

WS每Tile有效计算为P×ws_cnt拍，P=A位宽/4；ws_cnt仍是完整ACT/Context数，Psum深度不乘phase。单bank先收后发，含ACT收集每Tile占2×P×ws_cnt个时钟沿。

容量结论：完整ACT为256×A位宽bit，最大4096；WS逐Context换入，AS跨Context保持同一份ACT，OS逐Tile换入。因此容量不乘ws/as/os。必须遵守首命令ready及后续ACT连续输入，单bank不支持接收下一包与内部发射重叠。--act-buffer提供280个全Plane容量case，覆盖七精度、两种符号、os1/2、1/2/16 Context及命令空拍。

输出保持raw_data为未加requant的测试版本，每OC 32 bit（32路共1024 bit）；最终每OC输出8 bit（共256 bit）。requant逻辑与流水不计入当前DFF统计。
