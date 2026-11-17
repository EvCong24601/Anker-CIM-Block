# RTL 与验证辅助文件索引

当前接口与时序见[raw 契约](Cluster_Raw_Output.md)、[流水总览](Cluster_Pipeline.svg)和[Testbench 指南](Testbench_Guide.md)。旧 Requant 单元和测试已删除。

## Cluster 功能源码

- [cluster_func.sv](../RTL/cluster/rtl/cluster_func.sv)
- [cluster_pkg.sv](../RTL/cluster/rtl/cluster_pkg.sv)
- [cluster_top.sv](../RTL/cluster/rtl/cluster_top.sv)
- [ClusterReduceTree.sv](../RTL/cluster/rtl/ClusterReduceTree.sv)
- [filelist.f](../RTL/cluster/rtl/filelist.f)

## Macro 功能源码

- [filelist.f](../RTL/macro/rtl/filelist.f)
- [MacroClockGate.sv](../RTL/macro/rtl/MacroClockGate.sv)
- [MacroCompress42.sv](../RTL/macro/rtl/MacroCompress42.sv)
- [MacroFullWeightPairLUT.sv](../RTL/macro/rtl/MacroFullWeightPairLUT.sv)
- [MacroMul2x4.sv](../RTL/macro/rtl/MacroMul2x4.sv)
- [MacroSliceFusion.sv](../RTL/macro/rtl/MacroSliceFusion.sv)
- [MacroW8MainCorrection.sv](../RTL/macro/rtl/MacroW8MainCorrection.sv)
- [MacroW8MainEntry.sv](../RTL/macro/rtl/MacroW8MainEntry.sv)
- [MacroW8MainOC.sv](../RTL/macro/rtl/MacroW8MainOC.sv)
- [MacroW8MainTree.sv](../RTL/macro/rtl/MacroW8MainTree.sv)
- [MacroW8MainTreeCSA.sv](../RTL/macro/rtl/MacroW8MainTreeCSA.sv)
- [MacroWeightSRAM.sv](../RTL/macro/rtl/MacroWeightSRAM.sv)
- [single_macro_func.sv](../RTL/macro/rtl/single_macro_func.sv)
- [single_macro_pkg.sv](../RTL/macro/rtl/single_macro_pkg.sv)
- [SingleMacro.sv](../RTL/macro/rtl/SingleMacro.sv)

## Cluster 测试顶层

- [cluster_check_func.sv](../RTL/cluster/tb/cluster_check_func.sv)
- [ClusterGemmOs1Ws32.sv](../RTL/cluster/tb/ClusterGemmOs1Ws32.sv)
- [ClusterGemmOs2As4.sv](../RTL/cluster/tb/ClusterGemmOs2As4.sv)
- [ClusterGemmScenario.sv](../RTL/cluster/tb/ClusterGemmScenario.sv)
- [filelist.f](../RTL/cluster/tb/filelist.f)
- [latency_audit.sv](../RTL/cluster/tb/latency_audit.sv)
- [tb_Cluster.sv](../RTL/cluster/tb/tb_Cluster.sv)
- [tb_Cluster_GEMM_OS1_WS1_AS8_W8A16.sv](../RTL/cluster/tb/tb_Cluster_GEMM_OS1_WS1_AS8_W8A16.sv)
- [tb_Cluster_GEMM_OS1_WS32_W8A16.sv](../RTL/cluster/tb/tb_Cluster_GEMM_OS1_WS32_W8A16.sv)
- [tb_Cluster_GEMM_OS2_AS4_W8A16.sv](../RTL/cluster/tb/tb_Cluster_GEMM_OS2_AS4_W8A16.sv)
- [tb_Cluster_GEMM_W2A8_HighGroup.sv](../RTL/cluster/tb/tb_Cluster_GEMM_W2A8_HighGroup.sv)
- [tb_Cluster_GEMM_W4A16_HighGroup.sv](../RTL/cluster/tb/tb_Cluster_GEMM_W4A16_HighGroup.sv)
- [tb_Cluster_GEMM_W4A16_N6_Tail.sv](../RTL/cluster/tb/tb_Cluster_GEMM_W4A16_N6_Tail.sv)
- [tb_Cluster_GEMM_W4A16_RoundClip.sv](../RTL/cluster/tb/tb_Cluster_GEMM_W4A16_RoundClip.sv)
- [tb_ClusterChannels.sv](../RTL/cluster/tb/tb_ClusterChannels.sv)
- [tb_ClusterReduceTree.sv](../RTL/cluster/tb/tb_ClusterReduceTree.sv)

## Cluster 测试共用文件

- [cluster_channel_driver.svh](../RTL/cluster/tb/include/cluster_channel_driver.svh)
- [cluster_completion_checks.svh](../RTL/cluster/tb/include/cluster_completion_checks.svh)
- [cluster_compute_cases.svh](../RTL/cluster/tb/include/cluster_compute_cases.svh)
- [cluster_driver.svh](../RTL/cluster/tb/include/cluster_driver.svh)
- [cluster_dw_k256_cases.svh](../RTL/cluster/tb/include/cluster_dw_k256_cases.svh)
- [cluster_empty_batch_cases.svh](../RTL/cluster/tb/include/cluster_empty_batch_cases.svh)
- [cluster_gate_checks.svh](../RTL/cluster/tb/include/cluster_gate_checks.svh)
- [cluster_gate_equivalence.svh](../RTL/cluster/tb/include/cluster_gate_equivalence.svh)
- [cluster_gemm_as_driver.svh](../RTL/cluster/tb/include/cluster_gemm_as_driver.svh)
- [cluster_gemm_as_regression.svh](../RTL/cluster/tb/include/cluster_gemm_as_regression.svh)
- [cluster_gemm_as_scoreboard.svh](../RTL/cluster/tb/include/cluster_gemm_as_scoreboard.svh)
- [cluster_gemm_driver.svh](../RTL/cluster/tb/include/cluster_gemm_driver.svh)
- [cluster_gemm_regression.svh](../RTL/cluster/tb/include/cluster_gemm_regression.svh)
- [cluster_gemm_scenario_driver.svh](../RTL/cluster/tb/include/cluster_gemm_scenario_driver.svh)
- [cluster_gemm_scenario_regression.svh](../RTL/cluster/tb/include/cluster_gemm_scenario_regression.svh)
- [cluster_gemm_scenario_scoreboard.svh](../RTL/cluster/tb/include/cluster_gemm_scenario_scoreboard.svh)
- [cluster_gemm_scoreboard.svh](../RTL/cluster/tb/include/cluster_gemm_scoreboard.svh)
- [cluster_mask_cases.svh](../RTL/cluster/tb/include/cluster_mask_cases.svh)
- [cluster_path_cases.svh](../RTL/cluster/tb/include/cluster_path_cases.svh)
- [cluster_pipeline_cases.svh](../RTL/cluster/tb/include/cluster_pipeline_cases.svh)
- [cluster_reference.svh](../RTL/cluster/tb/include/cluster_reference.svh)
- [cluster_regression.svh](../RTL/cluster/tb/include/cluster_regression.svh)
- [cluster_scoreboards.svh](../RTL/cluster/tb/include/cluster_scoreboards.svh)
- [cluster_sram_cases.svh](../RTL/cluster/tb/include/cluster_sram_cases.svh)
- [cluster_sram_response_cases.svh](../RTL/cluster/tb/include/cluster_sram_response_cases.svh)
- [cluster_suites.svh](../RTL/cluster/tb/include/cluster_suites.svh)

## Macro 测试共用文件

- [macro_driver.svh](../RTL/macro/tb/include/macro_driver.svh)
- [macro_negative_cases.svh](../RTL/macro/tb/include/macro_negative_cases.svh)
- [macro_reference.svh](../RTL/macro/tb/include/macro_reference.svh)
- [macro_regression.svh](../RTL/macro/tb/include/macro_regression.svh)
- [macro_scoreboard.svh](../RTL/macro/tb/include/macro_scoreboard.svh)

## Python 工具

- [audit_channels.py](../RTL/cluster/tb/py/audit_channels.py)
- [audit_latency.py](../RTL/cluster/tb/py/audit_latency.py)
- [buffer_schedule.py](../RTL/cluster/tb/py/buffer_schedule.py)
- [gemm_os1_ws1_as8_w8a16_vectors.py](../RTL/cluster/tb/py/gemm_os1_ws1_as8_w8a16_vectors.py)
- [gemm_os1_ws32_w8a16_vectors.py](../RTL/cluster/tb/py/gemm_os1_ws32_w8a16_vectors.py)
- [gemm_os2_as4_w8a16_vectors.py](../RTL/cluster/tb/py/gemm_os2_as4_w8a16_vectors.py)
- [gemm_scenario_vectors.py](../RTL/cluster/tb/py/gemm_scenario_vectors.py)
- [generate_readme.py](../RTL/cluster/tb/py/generate_readme.py)
- [requant_vectors.py](../RTL/cluster/tb/py/requant_vectors.py)
- [run_regression.py](../RTL/cluster/tb/py/run_regression.py)
- [run_sram_regression.py](../RTL/cluster/tb/py/run_sram_regression.py)
- [svfiles.py](../RTL/cluster/tb/py/svfiles.py)
- [verify_manifest.py](../RTL/cluster/tb/py/verify_manifest.py)

## 历史边界

`RTL/macro/SingleMacro_SPEC_v0.2.md` 是单拍历史实现；`buffer_schedule.py`、`audit_latency.py` 和 `latency_audit.sv` 保留旧 combined-command 调度。它们不定义当前输入握手。当前 42 组写入表由已更新的 generate_readme.py 独立生成。历史 Requant、资源统计及旧 Word 见各文档版本说明和 history 目录。
