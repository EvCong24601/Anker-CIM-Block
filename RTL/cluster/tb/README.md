# Cluster 原始 Psum 验证

TB 通过正式端口 raw_psum[1023:0]、psum_valid[31:0] 检查 signed32 原始点积、物理 lane 布局及准确周期。量化单元、量化输出及其专用用例已删除。

默认测试覆盖七精度、符号模式、26种归约树、OC mask、OS/WS/AS、tmp/Psum 路由及门控保持。GEMM 检查原始矩阵，不检查 INT8 结果。空批次/最早下一批次以及门控开关对照仍保留。

从仓库运行 python RTL/cluster/tb/py/run_sram_regression.py；--full 运行全部目录化用例，--case 选择用例，--sim-dir 指定仓库外快照。脚本读取与 VCS 相同的 filelist 和 cases.py，用 sources.json 记录快照文件散列。

从 vcs-rtl 运行 make list、make run CASE=cluster_default、make gemm-regression。详见 [VCS说明](../../../vcs-rtl/README.md) 和 [raw输出契约](../../../docs/Cluster_Raw_Output.md)。
