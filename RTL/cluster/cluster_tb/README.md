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

在本目录执行 `python py/run_regression.py --gate-unit --mixed-context --latency-audit --log regression_single_tmp_default.log`。脚本也可从仓库根目录或其他目录调用；入口把源码和检查脚本复制到仓库外的 cluster_tb_work/local_sim/<日志名>，work、CSV、日志和波形均在副本内生成；--sim-dir 可指定仓库外目录。该副本不提交 Git，仓库 data/log 仅保存经核对的结果。

## 流水与存储

每个 OC 仅一个 tmp 数据寄存器，以及深度 OUTPUT_BUFFER_DEPTH（默认16）的 Psum Context buffer。每 OC 共用一套 fusion 和一套 acc；同一 OC 每拍仅选择一个 Context entry，其他深度保持。

WS/单 Context：归约 R 与旧 tmp 做融合后写入 tmp，A0 直接覆盖；下一拍消费 tmp。os=1 最后 phase 直接输出，不写 Psum；os>1 仅最后 phase 填充或累加 Psum[ctx]。旧 tmp 的 acc 与新归约数据的 fusion 可同拍位于 tmp 两侧，属于不同输入结果。

AS：归约 R 先写 tmp，下一拍首 Tile/A0 填充 Psum[ctx]，后续 Tile/A0 做 acc，高 phase 做 fusion。AS A8/A16 在 os=1 时也使用 Psum 保存各 Context 的 fusion 历史，跨 Tile acc 关闭；AS A4 os=1 直接输出。

门控：tmp_input_cg_en 提前 tmp 捕获一拍；psum_cg_en 在捕获 tmp 时预测下一拍的唯一 Context 写回。首 Command 开放低 max(ws,as) 个所需 Psum entry，高地址整批关闭；WS os=1 和 AS A4 os=1 全关。门控请求逐 OC 至多一位有效，实际 ICG 时钟与关闭 DFF 保持由 TB 检查。

同一结果的 fusion 和 acc 不串联。WS 归约末级与 fusion 在 tmp 前的路径需要 STA；AS 在 tmp 后二选一。未用组合块两个输入隔离为零。参考实现使用 longint，最终 raw signed32，未包含 requant，未做生产综合/STA/功耗签核。

## Reduce tree 与时延

t1..t6 是向父级转发的 DFF。Pair 结束时从 t3..t6 前取数并关闭转发 DFF；quad 结束时从 t1/t2 前取数并关闭它们；仅继续归约时打开。`reduce_cg_en` 仍提前 1T，接 ICG。没有独立 root-only DFF 或统一末级对齐流水。

从实际 Macro 发射 Cq：叶子/pair 在 C(q+2) 捕获 tmp、C(q+3) 运算完成；quad 在 C(q+3)/C(q+4)；root 在 C(q+4)/C(q+5)。标准 W2/W4/W8 完整延迟为 **3T/4T/5T**。混合树各 channel 按自身深度直接发布各自 lane，浅层 lane 不等深层，同 lane 按 Context 顺序发布。同批 Context 使用同一 descriptor 布局。输入停顿和 requant 不含在上述周期中。

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
python py/run_regression.py --gate-unit --mixed-context --latency-audit --log regression_single_tmp_default.log
python py/run_regression.py --en 81 --oc 84218421 --os 2 --depth 3 --patterns 2 --log regression_single_tmp_sparse_depth3.log
```

默认1368个Cluster case：1200穷举数据case、84标准时序case、28 Command空拍/多Context交错case、56三Tile/三Context极值case。另有208个reduce-tree门控单元case。EN=FF时每符号合法split数为1,1,16,16,16,25,25，每组有效K严格小于256。AS 复用拍会故意改变外部 ACT，检查实际计算始终使用已保存的 Plane。

检查独立整数点积、每channel到达周期、WS唯一tmp状态、AS（含os=1融合）的逐phase Psum历史、旁路 case 的 Psum保持、未用加法器输入隔离、真实ICG时钟、关闭DFF保持、高地址深度整批关闭和按序发布。`--latency-audit` 启用 `sv_code/latency_audit.sv`，采集 [latency_audit.csv](data/latency_audit.csv) 的140个标准Context输出；`py/audit_latency.py` 按六种配置公式核对，生成 [latency_audit_validation.log](log/latency_audit_validation.log)。Python检查器只依赖标准库，无需本地Word文档。

要求 ModelSim 的 vlib/vlog/vsim 在 PATH。Python 入口按顺序编译 sv_code 中的源文件，自动定位 `../../macro/rtl`；也可用 `--macro-rtl PATH` 指定。`filelist.f` 可从本目录手动编译，仿真时选择具体顶层。`+DATA_DIR=路径` 控制 SV 的 CSV 输出位置，Python 入口自动传入本地副本的绝对 data 路径；直接运行 TB 时默认当前工作目录。

OS_TILES 控制穷举 suite，范围1..14。UINT W8A16 的 ACT 限制到0..32768/os_cnt-1，使最终结果保持 signed32。验证入口对应的日志为 `log/regression_single_tmp_default.log`、`log/regression_single_tmp_default_reduce_gate.log`、`log/regression_single_tmp_sparse_depth3.log` 和 `log/latency_audit_validation.log`。

混合 Context 定向 suite 通过 --mixed-context 启用，额外24例覆盖 W4A4/A8/A16、两种符号、os=1/2、WS/AS双 Context，以及 pair/quad 同拍发布不同 Context。内部 Context 标签按 lane 保存。FSDB 由 CLUSTER_FSDB 宏控制，VCS Makefile 开启；ModelSim 默认不开启。--depth 设置 OUTPUT_BUFFER_DEPTH，--psum-depth 为同一参数的命令行别名。

Cluster 数据 DFF 分布见[仓库首页](../../../README.md#cluster-数据-dff-位置)：ACT1024、归约中间级464、唯一tmp2048、Psum2048×OUTPUT_BUFFER_DEPTH、输出保持1024 bit；不含控制寄存器及SingleMacro内部。
