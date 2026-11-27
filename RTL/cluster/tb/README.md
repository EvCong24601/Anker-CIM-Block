# Cluster 原始 Psum 验证

TB 通过正式端口 raw_psum[1023:0]、psum_valid[31:0] 检查 signed32 原始点积、物理 lane 布局及准确周期。量化单元、量化输出及其专用用例已删除。

默认测试覆盖七精度、符号模式、26种归约树、OC mask、OS/WS/AS、tmp/Psum 路由及门控保持。GEMM 检查原始矩阵，不检查 INT8 结果。空批次/最早下一批次以及门控开关对照仍保留。

用 `--case channels` 单独运行控制切换与缺操作数测试。用例驱动真实权重和 ACT，对每个输出 lane 检查点积和采样沿，并检查新 cmd 的最早握手沿。用例目录的 `data/channel_audit.json` 汇总了缺数据时仍有输出的周期数和切换空泡分布。

`cluster_mbist_serial` 依次对 Macro 0–7 执行故障检测，再逐个回灌 64-bit 修复码复测，并在故障保持的条件下检查每个 Macro 的功能读写。Cluster 共用的 `mbist_repair_we_i` 配合 Macro ID，只在 `we=1` 的时钟上升沿更新选中 Macro 的本地 64-bit 寄存器；`mbist_repair_done_o[7:0]` 在对应写入边沿后第 3 个时钟沿置位并保持。旧的单比特 `mbist_repair_done_i` 暂时停用。`cluster_mbist` 额外检查 write enable 低时配置保持、start 不触发修复写入、独立配置复位及 8 位标志的时序。串行测试逐字节检查 Cluster 顶层每个 Macro 的 8 个 8-bit 错误寄存器，在自身测试进行中和其他 Macro 运行期间保持原值。结果采样增加一拍，`mbist_test_done_o` 与寄存后的结果一起更新。VCS 从 `vcs-rtl/` 运行 `make run CASE=cluster_mbist_serial`；无 HVT FA/HA 仿真库时，从仓库根目录运行 `python RTL/cluster/tb/py/run_sram_regression.py --csa-golden --case cluster_mbist_serial`。另有 `cluster_mbist_serial_ungated` 检查关闭门控的路径。`lib/hdsram256w512btop_tt_scalar.lib` 是模板提供的估算时序库，不是经过 PVT 表征的 signoff 库。

定向用例 `dw_k256_w2`、`dw_k256_w4`、`dw_k256_w8` 通过三通道发数，分别启用 2/4/8 个 Macro 覆盖 K=256。覆盖全部支持的 A 精度、符号、OS/WS/AS、物理 Macro 置换和全部合法 ACT 槽。逐 issue 核对完整 512 bit Macro 输入、真实 ACT bank 时钟及保持，逐 lane 核对完整点积与采样沿，并比较门控开关。还覆盖 zero/multi OC、enable mask 变化、独立与合并归约、空有效工作及同配置交接。`dw_k256_invalid_slot` 和 `dw_k256_invalid_duplicate` 分别核对越界槽和同组重复槽拒绝。

从仓库运行 python RTL/cluster/tb/py/run_sram_regression.py；--full 运行全部目录化用例，--case 选择用例，--sim-dir 指定仓库外快照。脚本读取与 VCS 相同的 filelist 和 cases.py，用 sources.json 记录快照文件散列。

当前 Macro 使用两拍 LUT/CSA 实现。没有 HVT FA/HA 库时，加 `--csa-golden`，编译会定义 `MACRO_W8_CSA_GOLDEN`，由 `MacroW8MainTree` 例化数学模型。`summary.log` 标注所选模型。此模式覆盖功能与接口时序。详见 [Macro 说明](../../macro/README.md#无工艺库的-golden-model-仿真)。

固定/golden CSA 的 correction 输入均接零。Macro 在 n+1 保存共享的 4 bit 模式信息，第二拍译码 correction 并直接加到 CPA。Cluster 检查共享模式的捕获与保持，以及原有每 OC 的 CSA/结果门控，数值仍由独立整数点积逐 lane 核对。

从 vcs-rtl 运行 make list、make run CASE=cluster_default、make gemm-regression。详见 [VCS说明](../../../vcs-rtl/README.md) 和 [raw输出契约](../../../docs/Cluster_Raw_Output.md)。

两个定向用例均使用 `tb_ClusterChannels`，先从公开 SRAM 口写入权重，再发送 signed、AS=WS=1 的命令。下一条命令仅在 `cmd_ready_o` 的可接收窗口送出，按上升沿的 `cmd_valid_i && cmd_ready_o` 计入握手。

- `w8a8_os128_to_w4a8_os64`：W8A8 OS=128 的最后一个 phase 与 W4A8 OS=64 的命令握手同沿，下一拍 issue W4A8 的第一个 phase。检查 384 个连续 issue 和 8 个有效 lane 结果。
- `w8a8_os1_128_cmds`：128 条 W8A8 OS=1 命令，每条两个 phase；逐个检查 127 个边界、256 个连续 issue 和 512 个有效 lane 结果。

在 `vcs-rtl/` 用 `make run CASE=<用例名>` 运行。在 `data/channel_cycles.csv` 查看 `next_issue_bubbles`；除最后一条没有后继命令（记为 −1），其余各行应为 0。

`pipeline_config` 定向用例逐字段及组合切换 ACT slot、符号、同 A 精度下的 W 精度和兼容计数。414 对任务均要求 next_cmd_accept=old_last_issue、next_first_issue=old_last_issue+1；独立整数点积核对全部有效 lane 和采样沿，门控开关逐拍对照。覆盖 WS64→1、AS8→2 及反向扩展；额外核对各级 51 bit 来源、tmp/发布级配置捕获保持和真实 Psum Context 时钟。不兼容路径、A位宽或累加模式变化时验证排空；同类跨 split 的快速交接由下述 path_class 覆盖。

`mask_pipeline` 覆盖七精度、三种累加模式及独立/两路/四路/八路/混合深度归约的 enable/OC mask 切换；逐对要求末次 issue 同沿接收下一 cmd、下一沿连续 issue。包括 enable 单独全零、OC 单独全零、组合清空与恢复、交替 mask、Context 数缩小，以及旧深路径→空/浅路径→不兼容配置的连续任务。检查真实 Macro/归约/tmp/Psum 时钟与保持、各级配置来源、逐 lane 数值及准确采样沿。`channel_cycles.csv` 的 `prior_drain` 为所有不兼容旧任务的最晚输出采样沿与前任务末次issue沿的较大值，不能只看最近一个可能为空的任务。

`path_class` 在每个任务只有一种有效归约宽度的约束下，遍历 canonical split 和七精度/三种模式；关闭其他宽度的组，覆盖 Reduce-1↔2、Reduce-4 同类跨 split、Reduce-8 同类保持、OC/组关闭、Context 数缩小及21条三任务链。独立树遍历与整数点积核对类别、lane映射、数值及采样沿，真实 ICG 与配置保持检查继续开启；深任务→不同 split 的空任务→不兼容类别验证全在途保护，空任务不能成为新类别的绕过入口。混合宽度仍由原有回归覆盖，不作为本用例的快速路径输入。
