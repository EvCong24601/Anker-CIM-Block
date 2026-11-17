# Cluster 当前验证口径

检查依据为当前 RTL、`vcs-rtl/cases.py` 和独立数值模型；正式输出为 raw_psum/psum_valid。旧 Requant 的量化向量数量、INT8 时序和旧包调度覆盖不作为当前回归结论。

## 当前流水检查

- SingleMacro：输入 n、CSA n+1、CPA 结果 n+2，II=1；刷新与同地址复用延迟一致。
- ReduceTree：tap 在组合端点取值，只有继续归约才写 pair/quad forwarding DFF；按本笔对齐配置开钟。
- tmp/Psum：Reduce-1/2、4、8 分别在 issue+3/+4/+5 写 tmp；Psum 再晚一拍，最终值沿后有效，下游下一沿采样。
- 配置：51 bit cfg 随五级 metadata、三个 tmp 端点和三个 Psum 发布路径传递；覆盖 mask、Context 缩小及旧深路径尚未完成。
- 三通道：每路独立握手、旧任务最后 beat 优先、直通/缓存、缺数时在途结果正常排出。
- 交接：兼容新 cmd 在旧任务末 issue 沿接收，供数及时则下一沿 issue；检查全部在途事务，空任务不能绕过旧类别保护。

## 已有完整回归记录

2026-11-17 `path_class_20261117_full`：117/117 通过，其中35项正常用例、82项预期拒绝；七组 GEMM 的1,504个 signed32 输出全部匹配。path_class 覆盖2,247个任务、1,092对同类交接及21条三任务链。完整记录与模型边界见[接口契约验证章节](Cluster_Raw_Output.md#2026年11月17日实际路径类别-split-交接验证)。这些是已有回归结果，本次文档整理未重新执行117项全量回归。

## 本次重新执行

`../cluster_tb_work/local_sim/docs_pipeline_20261117/` 使用当前源码新建快照。channels 通过657个任务；438个连续供数任务内部 issue 无空拍，缺数期间仍有输出的周期为682。`timing_figure/` 的5任务定向激励通过，验证72个有效 lane 输出；图中 C133～C154 来自这次实测。

源文件哈希见快照 sources.json；仿真结果见 channels/sim.log、summary.log、timing_figure/sim.log 及对应 CSV。此次未修改功能 RTL 或 TB 激励。CSA 使用无工艺依赖的数学 golden，实际 LUT、寄存边界、CPA、cfg 和 ICG 保留；不包含固定单元连线仿真、综合、PPA 或 STA。

## 复现

运行 `python RTL/cluster/tb/py/run_sram_regression.py --csa-golden --case channels --sim-dir ../cluster_tb_work/local_sim/docs_pipeline_20261117`，再在快照目录运行 `tb_ClusterChannels +TIMING_FIGURE`。全量回归以 `--full` 替换 `--case channels`。详细入口见[Testbench 指南](Testbench_Guide.md)。
