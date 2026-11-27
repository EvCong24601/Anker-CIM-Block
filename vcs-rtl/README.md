# VCS 原始 Psum 仿真

从本目录运行，源文件和include路径相对于本目录。当前Cluster输出为raw_psum[1023:0]、psum_valid[31:0]，无Requant参数或INT8输出。

```sh
make list
make run CASE=cluster_default
make run CASE=channels
make run CASE=w8a8_os128_to_w4a8_os64
make run CASE=w8a8_os1_128_cmds
make run CASE=gemm_os1_ws32_as1_w8a16_raw
make gemm-regression
make regression
```

make run依次生成输入、编译、仿真并核对预期结果。cases.py是用例目录，cases.mk由python cases.py --write生成。每个用例位于work/<CASE>/，包括data、compile.log、sim.log、sim.exit和波形。

make com使用verilog_file_<TB>.f；Cluster与GEMM清单引用verilog_file_common.f，Macro使用独立清单。+incdir覆盖cluster/macro的rtl和tb目录。函数通过include读取，不作为独立编译单元。

VCS 默认例化固定门级 CSA，展开需要 HVT FA/HA 仿真库。功能仿真可用 `make run CASE=macro_gate1 PARAMETERS=+define+MACRO_W8_CSA_GOLDEN` 选择[数学 golden model](../RTL/macro/rtl/MacroW8MainTreeCSA_golden.sv)。从仓库根目录运行 `python RTL/cluster/tb/py/run_sram_regression.py --csa-golden --full` 会在 ModelSim 中定义同一个宏。

当前有119个用例，覆盖三通道握手、配置切换、缺操作数时在途结果排出、默认raw算术、SRAM访问和互斥、count/Context容量拒绝、OS255/256/511、归约门控、Macro协议、空批次、DW及7种GEMM几何。用 `make run CASE=act_buffer_write_enable` 检查 ACT 末次直通时的数据保持、AS 跨 Context 复用和同沿替换 plane。原有round_clip场景名保留输入矩阵几何，当前检查raw点积。

两个 OS 交接用例均为 signed、AS=WS=1。`w8a8_os128_to_w4a8_os64` 检查 W8A8 OS=128 切换到 W4A8 OS=64 的 384 个连续 issue 和 8 个输出；`w8a8_os1_128_cmds` 检查 128 条 W8A8 OS=1 命令的 127 次无空拍交接和 512 个输出。运行后，`work/<CASE>/data/channel_cycles.csv` 记录每条命令的握手、首末 issue 和最后输出周期。用 `make wave CASE=<CASE>` 打开对应 FSDB。

GEMM raw结果CSV为m,n,raw；Python按矩阵坐标验证每个signed32结果，拒绝缺失或重复元素。波形含正式raw输出端口，数据无效时不作保持假设。

接口详见[raw输出契约](../docs/Cluster_Raw_Output.md)。本地ModelSim快照回归入口为RTL/cluster/tb/py/run_sram_regression.py。实际VCS执行需要用户的Linux工具环境；本地验证使用ModelSim。

逐级51bit配置与兼容字段切换测试：`make run CASE=pipeline_config`。无工艺库时使用 ModelSim golden 入口的 `--case pipeline_config`。

enable/OC mask 无bubble切换及在途路径占用测试：`make run CASE=mask_pipeline`；ModelSim golden 入口使用 `--case mask_pipeline`。

单宽度任务的同实际路径类别 split 交接测试：`make run CASE=path_class`；ModelSim golden 入口使用 `--case path_class`。

[总体控制切换 README](../docs/Cluster_Control_Switching_README.md) · [case 切换与 bubble 详细表](../docs/Cluster_Control_Switching_README.md#switch-cases)
