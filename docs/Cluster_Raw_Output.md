# Cluster 原始 Psum 输出接口

2026年11月3日起，cluster_top 移除 Requant，直接输出完整的 signed32 累加结果。本文与当前 RTL 是接口依据。

## 输出定义

- raw_psum[1023:0]：32 个物理 lane，每个 lane 为 32 bit。lane l 对应 raw_psum[32*l+:32]，按 signed32 解释。
- psum_valid[31:0]：每 bit 对应同编号 lane，仅在该 bit 为 1 的周期采样对应数据。允许多个归约组同时发布，最多 32 个 lane 有效。
- 输出无 ready、无反压。接收端必须能在有效周期接受数据；无效 lane 的 payload 不保证保持或为零。
- reset_n 为低电平有效异步复位，下降沿清除有效位；复位期间 psum_valid=0。释放须由集成端同步并满足恢复/移除时序。
- reset_n 仅连接有复位状态的子模块，不参与 ready、请求或 ICG/SRAM 使能的组合译码。cmd_ready_o 不保证在复位期间为0；Command握手仅在 reset_n=1 时有效。MacroWeightSRAM 是无复位 wrapper，上层必须在复位期间将 sram_cs_en 置0；直接使用 SingleMacro 时还须将 cim_ren、sram_wen、sram_ren 置0。在访问使能无效时，SRAM阵列和内部读出保持值保持；wrapper 不会自动屏蔽复位期间的访问。

raw_psum 组合读取现有 tmp/Psum。tmp 路径在最终结果写入 tmp 后发布，Psum 路径在最终写回后发布。以 lane 对应的末次 issue 沿为 C0，1/2、4、8 个 Macro 的归约组分别在 C3、C4、C5 沿后发布 tmp，Psum 路径各晚一拍。同步接收端在下一个上升沿采样。

以 W8A8、OS=WS=AS=1、8 个 Macro 同组为例，C0 同沿接收 cmd、权重地址和 A0。C1 发射 A0 并接收 A1，C2 发射 A1。两个 Macro phase 结果分别在 C3、C4 沿后可见，两个根和在 C6、C7 写入 tmp。C7 写入融合值并置有效，同步接收端在 C8 采样。[流水与 ICG 图](Cluster_Pipeline_ICG.svg)

## Command、权重地址与 ACT

`cmd_i[0]` 为 `cim_dw_compact`，`cmd_i[1]` 为 `cim_signed_en`。沿用原 102 bit M1 命令向量的调用方应发送 `{old_cmd[101:0], cim_dw_compact}`，普通模式将新增位驱动为 0。两笔任务仅此位不同时也按异配置排空交接。

每项任务在 `cmd_valid_i && cmd_ready_o` 的上升沿接收一个完整的 103 bit `cluster_ctrl_t`。8 bit 权重行地址已从打包控制字移到 `weight_raddr_i`。同一任务只发送一次控制字。发送端有数据时即可驱动 payload 和 valid，并保持到对应 ready 握手。cmd_ready_o 会比较当前呈现的 cmd_i，以允许同配置提前交接。复位释放后，握手才有效。

- **权重地址**通过 `weight_valid_i && weight_ready_o` 传输。每个 Tile 接收 AS 个地址，共 OS × AS 个。WS 的多个 Context 和各 phase 复用同一地址。AS 的各 Context 使用各自的地址，多 phase 时复用已有 Context 地址表。
- **ACT** 通过 `act_valid_i && act_ready_o` 传输。设 P 为激活位宽除以 4，每个任务接收 OS × WS × P 个 1024 bit plane，顺序为 Tile、WS Context、从低到高的 phase。AS 的各 Context 复用同一 plane，最后一个使用者 issue 后该槽可接收新数据。
- **Issue** 优先读取当前 phase 和 Context 已缓冲的操作数。已经接收 cmd 的任务若仍缺其中一路，且该路当前握手的正是所需数据，可同沿直通到 Macro。两路也可同时直通。AS 复用的 ACT、WS 复用的地址和多 phase AS 的 Context 地址按后续需求保留。当前操作数尚未到齐时，只有 issue 等待，在途结果仍按原定拍点发布。
- **连续任务**由整个 103 bit 控制字判定配置是否相同。相同配置最早可在旧任务最后一次 issue 沿接收下一 cmd。配置改变时，发送端保持新 cmd，直至旧任务所有有效 lane 已排出，最早可在采样最后一个旧结果的同一沿接收。有效输出掩码为空时只需完成旧任务的 issue。内部仅持有当前 cmd。

发送端按任务顺序驱动每一路，每次握手前进一个地址或 plane。上一任务在该路的输入已全部握手后，可提前呈现新任务的首个输入。新 cmd 实际握手的 C0 沿，可同时接收任意已有效的首个操作数。两路均在 C0 握手时，首次 issue 为 C1。若地址在 C0 握手而 ACT 到 C6 才握手，首次 issue 就是 C6。先等待 cmd 握手再发送操作数的驱动也受支持。

相同配置连续供数时，C0 可同时完成旧任务末次 issue、新 cmd 握手以及新任务首组操作数写入。不同配置交接时，C0 可同时采样最后一笔旧输出并接收新 cmd 和首组操作数。切换时只作废旧配置遗留在无用深层的 pipe_meta.valid，ACT、地址、tmp 和 Psum 的有效性由各自的元数据限定。仍有贡献的旧结果按原配置完成。

同沿接收新 cmd 时，按各操作数通道剩余的输入数量判定归属。旧任务还缺的最后一个 beat 直通给旧任务；该路要到下一沿才能接收新任务的 beat。旧任务已经收齐的另一路可以在 cmd 握手沿接收新任务的首个 beat。两路都属于旧任务时，新 cmd 仍可握手，新任务的两个操作数从下一沿开始接收。

[单拍 Macro 版本的逐拍记录](Cluster_Issue_Timing.svg) 展示了地址晚到的情况。以下绝对拍号对应当时的仿真。C138 最后一次发射 A3 并接收同配置的 A4 cmd，该沿的权重地址归 A3。C139 接收 A4 自己的地址，C142 A4 的 ACT 到达并当拍 issue。发送端可以在旧任务最后一个操作数到达前呈现新 cmd 并保持到握手。在 tb_ClusterChannels 上使用 `+TIMING_FIGURE` 可复现图中激励。

每个 1024 bit plane 容纳 256 个 ACT 各自的一段 4 bit。A4、A8、A16 每帧分别传 1、2、4 个 plane。Cluster 原有的 4096 bit 缓冲按 phase 分为四个槽，后续 phase 可在之前的 phase 用完前接收。每个槽使用独立 ICG，写入条件是 `act_buffer_we && external_phase == p`。若直通的 ACT 在同沿用完，接收计数照常推进，四路时钟均关闭。AS 的后续 Context 还需该 plane 时，直通和缓存写入同沿完成。旧缓存数据最后一次被读取时，也可在同沿写入下一份 ACT。SingleMacro 的 ACT bank 仍由独立的 `act_capture_en` 控制。[C138、C139、C142 数据流](Cluster_Pipeline_A3_A4.svg)

## 数值与物理布局

输出为位融合及所有 OS Tile 累加后的原始点积，未应用 multiplier、shift、zero point、round 或 INT8 saturation。输入数据存在量化零点时，raw 点积也未减去输入偏置，后处理由下游完成。

lane 布局保持现有归约树的物理组编号与 OC 对应关系。被屏蔽的 OC 或无贡献路径不产生 valid；高组、空洞和多组输出不压缩到低 lane。WS/单 Context 从 tmp 读取，OS>1 或多 Context AS 从对应 Context 的 Psum 读取。

内部 tmp/Psum 仍为 signed32。调用方应保证每次中间写入及最终结果都在 signed32 范围内。仿真中的溢出检查不表示硬件带饱和器或溢出标志。

## 删除的接口与逻辑

已移除 requant_cfg_i、requant_cfg_t、requant_data_o、requant_valid_o、ENABLE_REQUANT、REQUANT_CONTEXT_DEPTH、ClusterRequant 实例及其 RTL 文件。批次/AS Context 的 scale、shift、ZP 存储、有效位、选择逻辑、四组配置时钟和 32 组 INT8 输出时钟全部移除。

cim_os_cnt/cim_ws_cnt/cim_as_cnt 各 9 bit，编码 1～511。MAX_CONTEXTS 和实际 buffer 深度限制继续生效，默认深度 16，默认 MAX_CONTEXTS=64。

## 编译与验证入口

从 vcs-rtl 运行 make run CASE=cluster_default，或 make run CASE=gemm_os1_ws32_as1_w8a16_raw。filelist 不再编译量化单元，原 Requant 用例和 scale/ZP reload 拒绝用例已从 cases.py、cases.mk 和 Makefile 入口删除。

TB 的独立数值模型通过公开 raw_psum/psum_valid 端口验证算术与时序。GEMM 结果 CSV 为 m,n,raw，Python 逐坐标对照 raw golden，拒绝重复或缺失结果。GEMM 向量生成器还保留旧接口的 input_schedule.csv、量化辅助文件及历史延迟参数。当前三通道逐拍时序见 channels 仿真采集的握手和 issue 记录。

本地入口：python RTL/cluster/tb/py/run_sram_regression.py；--full 运行全部 raw/协议用例，--case 可选择一个或多个用例，--sim-dir 指定仓库外的快照目录。需要将 vlib、vlog、vsim 加入 PATH。

三通道专项用例为 `channels`。其 data 目录下的 `channel_cycles.csv` 记录逐任务接收、首末 issue 和末次输出采样沿，`channel_events.csv` 记录逐拍握手，`channel_audit.json` 汇总相邻任务之间的空泡。空泡数定义为下一任务首次 issue 沿减去旧任务末次 issue 沿再减 1。

## 2026年11月16日紧凑 DW 验证

ModelSim 全量 116 项通过，含 84 项预期拒绝。W2、W4、W8 定向用例使用同一批权重、ACT 和逻辑任务，与 2026-11-13 M2 TC 修改包的原始 RTL 按事务对齐。464 次 issue（其中 456 次启用紧凑 DW）的各启用 Macro 完整输入、有效局部结果以及最终 1,032 个有效 lane 的 signed32 值均一致。M1 的 Macro 结果于 issue 后第 2 沿可见，M2 于第 1 沿可见。两个版本均拒绝合并归约组、启用 Macro 的零 OC 或多 OC、以及重复槽号。

## 2026年11月16日两拍 Macro 回归

ModelSim 全部 109 项通过，含 80 项预期协议拒绝。7 个 GEMM 矩阵的 1,504 个 signed32 结果逐坐标匹配 golden，矩阵文件与单拍版本逐字节一致。三通道专项中，连续供数的 438 项任务从首个到末个 issue 均无空拍。W8A8 八路归约的第 0 项任务在第 133 沿接收 cmd，第 134、135 沿发射两个 phase，第 141 沿采样最终结果。

## 2026年11月15日三通道回归（单拍 Macro）

专项用例连续运行 657 个任务，逐 lane 核对 22,728 个结果及其采样沿。根据公开握手轨迹独立核对每次 issue，其中只有 ACT、只有地址及双路同时直通分别命中 1,036、155、2 次。测试中有 626 个周期同时观察到任务因操作数未齐停发和在途结果有效。四次在旧任务最后一个或两个操作数直通的同一沿接收新 cmd，覆盖旧地址、旧 ACT 和双路旧数据。

224 次同配置交接实现了相邻拍连续 issue，其中 221 次在旧任务末次 issue 沿同时接收新 cmd 和新任务的两个首操作数。213 次从有输出的任务切换到不同配置时，新 cmd 均在旧任务末次输出采样沿握手。其中 211 次两个操作数同时到达，issue 空拍数为 3～6，取决于旧任务的归约组和 tmp/Psum 路径。另两次故意延迟一路操作数，分别有 13、15 个空拍。测试中的空掩码旧任务切换为 0 个空拍。

在发送端连续提供本任务所需输入的全部 438 个任务中，首末 issue 之间均未断发。若新任务首组数据及时，异配置交接的空拍数按旧任务最深有效归约组确定。组宽 1/2、4、8 的 tmp 路径分别为 3、4、5 拍，Psum 路径分别为 4、5、6 拍。空拍统计包含旧结果被采样的时钟沿。

ModelSim 全量 109 项通过（含 80 项预期拒绝），7 个 GEMM 用例的 1,504 个 signed32 结果均匹配。新增 `act_buffer_write_enable` 检查 C142 直通后全 bank 保持、AS=3 的三个 Context 复用同一 plane，以及末个 Context 读取旧 plane 时接收下一 tile 的 ACT。原三通道用例的 8,603 拍握手、issue 与输出有效掩码逐拍记录和修改前一致。

四路 Cluster ICG 的定向波形中，C142 四路均无跳变；C155 首次接收 AS plane 时仅 plane 0 出脉冲，C156 读取复用数据时四路均关闭，C157 同沿替换时仅 plane 0 出脉冲，C158 即用新数据发射。用 `../cluster_tb_work/local_sim/act_plane_icg_20261115_full/summary.log` 核对整套结果，用同目录 `channels/data/channel_events.csv` 和 `channels/data/channel_audit.json` 核对逐拍事件和统计。直通引入了从外部 ACT、地址和 valid 到 Macro/SRAM 输入及使能的组合路径。SYNTHESIS 宏分支编译通过，尚未运行工艺 STA。

## 2026年11月12日复位版本验证记录

2026年11月12日对低有效异步复位、无复位SRAM wrapper的最终版本完成验证。SRAM保留测试由上层保持访问请求无效，检查阵列和读出保持值；异步短脉冲测试检查在途事务取消。

- ModelSim全量回归：107项全部通过，包括27项正常用例和80项预期非法输入拒绝，无遗漏或非预期失败。
- 7种GEMM的1504个signed32输出全部匹配参考值；门控开/关、Cluster逐拍对照、归约树、SRAM读写/响应、输入重叠及容量边界均通过相应用例。
- 55个源码/include文件的语法树和16份编译清单复查通过：17个RTL异步复位模板全部低有效，未发现复位参与端口运算或组合使能译码；SRAM wrapper及其父实例没有复位引用，黑盒与Liberty接口一致。
- 编译快照、语法树快照和用例目录的哈希均与受测RTL/TB一致。SYNTHESIS分支编译通过；未执行实际VCS、工艺综合或STA。

从仓库根目录复现全量回归（需要ModelSim的vlib、vlog、vsim位于PATH）：

```sh
python RTL/cluster/tb/py/run_sram_regression.py --full --sim-dir ../cluster_tb_work/local_sim/resetless_sram_full_20261112
```

日志位于仓库外的 `../cluster_tb_work/local_sim/resetless_sram_full_20261112/`；`summary.log` 记录107项结果，`sources.json` 保存受测源码哈希，`reset_ast_audit.json` 保存复位检查结果。

## 输入 Macro 和输出 channel 的位序

所有固定打包字段采用低编号在LSB侧的约定。LSB描述向量内的bit排列，不表示Macro编号必然等于ACT slot或最终输出组编号。

### Macro编号与控制字段

Macro编号m为0～7。常规SRAM访问使用macro_id={sram_macro_group,sram_bank_sel}，即macro_id=4*sram_macro_group+sram_bank_sel。{0,2'b00}选Macro0，{1,2'b11}选Macro7；sram_wrdata整条1024bit只写选中的Macro，不按8个Macro切分。计算时使能的Macro共享当前issue选定的权重行地址，分别从各自的SRAM读取该行。

- cim_macro_en_mask[m]对应Macro m，bit0是Macro0。
- cim_macro_oc_mask[4*m+c]对应Macro m的本地OC c，c为0～3。
- cim_act_slot_sel[3*m+:3]给出Macro m的ACT slot，最低3bit属于Macro0。slot是可配置路由，不固定等于m。

### ACT和权重的局部元素顺序

普通模式（`cim_dw_compact=0`）下，设权重精度为W bit，单Macro的K长度Kmacro=256/W。W2/W4/W8分别为128/64/32，对应可选ACT slot数2/4/8。

外部每拍act_data_i提供一条1024bit ACT Plane。第phase条Plane存放各ACT元素的第phase个4bit digit，phase0先到，对应ACT最低4bit；后续依次为bit[7:4]、[11:8]、[15:12]，按A精度取1/2/4条Plane。

Macro m令slot=cim_act_slot_sel[3*m+:3]，局部K元素j的ACT digit来自Plane[4*(slot*Kmacro+j)+:4]，进入SingleMacro.cim_idata[4*j+:4]。因此slot0从Plane最低位开始，j=0位于该slot最低4bit。每个Macro的四个OC复用同一份ACT。

紧凑深度卷积（`cim_dw_compact=1`）对 W2、W4、W8 都使用 32 个 ACT digit。每个 phase 的 plane 有 8 个 128 bit 槽，`cim_idata[127:0] = plane[128*slot+:128]`，高 384 bit 填零。缓冲和当拍直通共享同一段选槽逻辑。配置须取 `cim_reduce_split_mask=7'h7f`，各启用 Macro 的槽号互异，每个启用 Macro 恰好打开一个 OC。结果发布在 `lane=4*m+c`，其中 c 是该 Macro 打开的 OC。SingleMacro 对每次 DW issue 仅开启低 128 bit ACT 时钟，高两个 bank 保持旧 Q。与 ACT 同沿寄存的 DW 标志将有效乘积限定在前 32 个 ACT digit 对应的 Slice，首个 DW phase 即可正确计算。权重按命令的 W 精度解码，Macro 计算延迟为两拍。

每条Macro权重行按四个OC连续排列：OC0为sram_wrdata[255:0]，OC1为[511:256]，OC2为[767:512]，OC3为[1023:768]。OC c的K元素j存放在sram_wrdata[256*c+W*j+:W]，元素0位于该OC区域LSB。sram_wmask[c]对应同编号OC，1保持、0写入。

SingleMacro的四个局部phase结果同样按OC从低位排列：cim_odata[18*c+:18]。Cluster内部先按Macro编号拼接，每个Macro占72bit，Macro0位于macro_data[71:0]。

### 归约组到正式输出lane

归约仅合并同编号OC：组内各Macro的OC0相加，OC1相加，依此类推。不同OC不会互相归约。

令g=group_of(cim_reduce_split_mask,m)，则Macro m的本地OC c最终贡献到lane=4*g+c。正式端口为raw_psum[32*lane+:32]，对应有效位psum_valid[lane]。输出按物理归约组g、再按本地OC c递增排列；被禁用的物理组或OC保留原位置，不压缩有效channel。

- 全部独立（split=7'h7f）：g=m，Macro0/OC0→lane0→raw_psum[31:0]；Macro0/OC3→lane3→[127:96]；Macro1/OC0→lane4→[159:128]；Macro7/OC3→lane31→[1023:992]。
- 八Macro全归约（split=7'h00）：全部属于g=0，八个Macro的同编号OC求和后仅使用lane0～3，即raw_psum[127:0]。
- 两个四Macro组（split=7'h01）：Macro0～3→g0→lane0～3；Macro4～7→g1→lane4～7。若只启用高组，结果仍在raw_psum[255:128]、psum_valid[7:4]，不会移动到最低128bit。

lane是物理结果槽位，并不自动等于网络的全局输出channel编号。全局channel还取决于软件给各Macro/OC装载的权重及当前AS Context；AS的不同Context会在不同有效周期复用相同物理lane。
