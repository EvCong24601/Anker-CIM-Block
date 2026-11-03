# VCS 原始 Psum 仿真

从本目录运行，源文件和include路径相对于本目录。当前Cluster输出为raw_psum[1023:0]、psum_valid[31:0]，无Requant参数或INT8输出。

```sh
make list
make run CASE=cluster_default
make run CASE=gemm_os1_ws32_as1_w8a16_raw
make gemm-regression
make regression
```

make run依次生成输入、编译、仿真并核对预期结果。cases.py是用例目录，cases.mk由python cases.py --write生成。每个用例位于work/<CASE>/，包括data、compile.log、sim.log、sim.exit和波形。

make com使用verilog_file_<TB>.f；Cluster与GEMM清单引用verilog_file_common.f，Macro使用独立清单。+incdir覆盖cluster/macro的rtl和tb目录。函数通过include读取，不作为独立编译单元。

当前有107个用例：默认raw算术、SRAM访问和互斥、count/Context容量拒绝、输入重叠、OS255/256/511、归约门控、Macro协议、空批次以及7种GEMM几何。Requant单元、scale/ZP reload和量化输出检查已删除。原有round_clip场景名仅保留输入矩阵几何，当前仅检查raw点积。

GEMM raw结果CSV为m,n,raw；Python按矩阵坐标验证每个signed32结果，拒绝缺失或重复元素。波形含正式raw输出端口，数据无效时不作保持假设。

接口详见[raw输出契约](../docs/Cluster_Raw_Output.md)。本地ModelSim快照回归入口为RTL/cluster/tb/py/run_sram_regression.py。实际VCS执行需要用户的Linux工具环境；本地验证使用ModelSim。
