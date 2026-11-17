# Testbench 文件与检查职责

当前正式结果为 raw_psum[1023:0]、psum_valid[31:0]，最多32个物理 lane 有效，无输出反压。TB 通过公开端口检查 signed32 点积、物理 lane 和准确采样沿。RTL 不包含 Requant 参数、运算或 INT8 输出。

## 当前入口

- `tb_Cluster.sv`：七精度、归约分组、OC/enable mask、OS/WS/AS、tmp/Psum、容量及实际门控。
- `tb_ClusterChannels.sv`：三路独立握手、缺数直通、每路输入归属、任务交接及全部在途约束；输出 `channel_events.csv` 和 `channel_cycles.csv`。
- `tb_ClusterReduceTree.sv`：组合端点、pair/quad 转发、祖先 mask 消费需求及真实 ICG 保持。
- `tb_SingleMacro.sv`：完整权重行、ACT 输入、两拍结果、刷新/复用、模式、OC/result mask 及门控。
- 七个具体 GEMM TB：通过常规 SRAM 口加载权重，输出 raw 矩阵并与 Python 整数点积逐坐标精确比较，见[GEMM 说明](Cluster_GEMM.md)。

## 流水检查

SingleMacro 在 n 捕获输入、n+1 捕获 CSA、n+2 捕获结果。相对末次 issue，归约端点在 +3/+4/+5 写 tmp；Psum 路径 +4/+5/+6 写回，下游采样再晚一沿。scoreboard 按 split 结构端点计算，不能按 W 精度或 enable popcount 代替。逐笔配置为51 bit，各级 cfg/phase/Context/Tile 与数据对齐。

`pipeline_config` 检查兼容字段及计数切换；`mask_pipeline` 检查 enable/OC 全零、恢复和旧深路径占用；`path_class` 检查同类跨 split、Reduce-1↔2、Reduce-4 和空任务后的在途保护。混合宽度保持同 split 规则。独立点积模型及采样沿检查不从 DUT 存储生成预期值。

## 文件与复现

`.svh` 在 TB module 内 include，不单独编译；当前文件清单见[源码索引](Source_Map.md)。`*_tb/py` 生成向量和检查结果，不属于功能 RTL。`buffer_schedule.py`、`audit_latency.py` 和 `latency_audit.sv` 属于旧包调度辅助工具，不用于当前三通道拍点结论。

当前逐拍表由 `python RTL/cluster/tb/py/generate_readme.py` 生成；该生成器使用 issue 相对拍点，不依赖旧输入包公式。

本地运行 `python RTL/cluster/tb/py/run_sram_regression.py --csa-golden --case channels --sim-dir ../cluster_tb_work/local_sim/docs_pipeline_20261117`。`--full` 运行目录化全部用例。无工艺库时仅以数学 golden 替换固定 CSA，LUT、CSA 寄存、CPA、配置流水及 ICG 保持真实 RTL；不构成固定单元连线仿真或 STA。

实测图使用同一编译快照运行 `vsim -c -lib work tb_ClusterChannels +TIMING_FIGURE +DATA_DIR=<输出目录> -do "run -all; quit -code 0"`，需在快照目录执行。C133～C154 来自该定向激励，不能作为任意驱动的固定绝对周期。
