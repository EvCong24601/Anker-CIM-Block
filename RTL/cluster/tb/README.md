# Cluster 原始 Psum 验证

TB 通过正式端口 raw_psum[1023:0]、psum_valid[31:0] 检查 signed32 原始点积、物理 lane 布局及准确周期。量化单元、量化输出及其专用用例已删除。

默认测试覆盖七精度、符号模式、26种归约树、OC mask、OS/WS/AS、tmp/Psum 路由及门控保持。GEMM 检查原始矩阵，不检查 INT8 结果。空批次/最早下一批次以及门控开关对照仍保留。

用 `--case channels` 单独运行控制切换与缺操作数测试。用例驱动真实权重和 ACT，对每个输出 lane 检查点积和采样沿，并检查新 cmd 的最早握手沿。用例目录的 `data/channel_audit.json` 汇总了缺数据时仍有输出的周期数和切换空泡分布。

定向用例 `dw_compact_w2`、`dw_compact_w4`、`dw_compact_w8` 通过三通道发数，覆盖各支持的 A 精度、缓存、直通、八槽置换、符号模式、OS/WS/AS 和仅切换 DW 位的任务交接。逐 issue 比较完整 512 bit Macro 输入，检查 DW 的三个 ACT 时钟为 001 及高位 Q 保持，逐 lane 核对 signed32 点积和采样沿。单 Macro 的门控和旁路测试还覆盖普通请求写入非零高位后连续进入 DW、再回到普通模式。四个 `dw_compact_invalid_*` 用例核对非法分组、零 OC、多 OC 和槽号重复的诊断。

从仓库运行 python RTL/cluster/tb/py/run_sram_regression.py；--full 运行全部目录化用例，--case 选择用例，--sim-dir 指定仓库外快照。脚本读取与 VCS 相同的 filelist 和 cases.py，用 sources.json 记录快照文件散列。

从 vcs-rtl 运行 make list、make run CASE=cluster_default、make gemm-regression。详见 [VCS说明](../../../vcs-rtl/README.md) 和 [raw输出契约](../../../docs/Cluster_Raw_Output.md)。
