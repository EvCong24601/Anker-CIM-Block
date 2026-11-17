# Cluster 三通道输入与流水调度

[接口契约](Cluster_Raw_Output.md) · [计算流水图](Cluster_Pipeline.svg) · [当前逐拍表](Cluster_Timing_Tables.md)

## 接收与发射

每任务只接收一次 102 bit cmd。cmd、8 bit 权重行地址和 1024 bit ACT plane 分别通过各自的 valid/ready 在上升沿握手。没有隐含的 Command+A0 捆绑传输，也不在每个 Context 重发命令。

设 P=A位宽/4。每任务接收 OS×AS 个地址和 OS×WS×P 个 ACT plane。地址按 Tile→AS Context 排列；ACT 按 Tile→WS Context→phase 排列。WS 复用权重，AS 复用同一 plane，多 phase AS 复用 Context 地址表。

AS 按 Tile→phase→Context issue；其他模式按 Tile→Context→phase issue。已接收任务的当前操作数可来自缓存，也可来自该沿握手的所需输入，两路均可直通。缺数仅暂停 issue，在途结果继续完成。

新命令和首操作数同时在 C0 接收时，首次 issue 最早为 C1。任务已接收后，所缺操作数在某沿握手可同沿 issue。四个 ACT plane 槽支持按 phase 写入、AS 保留复用，以及最后使用沿覆盖为下一份 plane；直通且当沿用完时不写 ACT 缓冲。

## 计算与结果边界

相对该笔 issue：I0 捕获 ACT/控制并刷新或复用 SRAM 行，I1 保存 CSA 中间结果，I2 经 CPA 与符号修正后保存 Macro 结果，II=1。

Reduce-1/2、Reduce-4、Reduce-8 分别在 I3/I4/I5 写 tmp，需要 Psum 时再晚一拍。这里的宽度是 split 结构端点，不是启用 Macro 数。各 tap 在转发 DFF 前取组合结果，仅继续归约时写 pair/quad 转发寄存器。

非 AS 在 tmp 前做 phase 位融合；OS>1 时末 phase 再写 Psum。AS 在 tmp 后按 Context 融合/累加，每 phase 写 Psum。最终值写入沿后发布 psum_valid，下游下一上升沿采样；raw_psum 组合读取现有存储，没有额外 raw payload DFF 或 Requant 一级。

## 任务交接与输入归属

当前输入任务仅持有一个完整 cmd。下游五级 pipe_meta、三个 tmp 端点及三个 Psum 发布端点保存各自对齐的 51 bit 配置，另带 phase、Context、首末 Tile 和有效标志。

兼容新 cmd 可在旧任务最后一次 issue 沿接收；新操作数及时供给时下一沿 issue。兼容判断覆盖全部实际在途事务，规则见[控制切换说明](Cluster_Control_Switching_README.md)。不同 split 不必一律排空；单一有效归约宽度任务可在同路径类别内快速交接。A 位宽、累加模式或不兼容路径改变时等待旧结果排空。

同沿接收新 cmd 时，每个操作数通道独立判断归属。旧任务仍缺的最后一个 beat 先供旧任务，该路下一沿才接收新任务 beat；已经收齐的另一路可同沿接收新任务首 beat。不能用新命令统一解释两路 payload。

## 容量与验证

默认 OUTPUT_BUFFER_DEPTH=16、WGT_RADDR_BUFFER_DEPTH=16、MAX_CONTEXTS=64。所有 AS 及 OS>1 的 WS 受 Psum 深度限制；多 phase AS 还受地址深度限制；TMP 模式 WS 可到 MAX_CONTEXTS。所有 count 为 1～511，WS/AS 不能同时大于 1。

不再使用旧 combined-command 的固定包周期公式。42 组示例统一以首次 issue 为 C0，逐笔列出 tmp、Psum、发布与采样沿。实际握手和等待见[三通道实测图](Cluster_Issue_Timing.svg)及 `channel_events.csv`、`channel_cycles.csv`。
