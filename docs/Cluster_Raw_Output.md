# Cluster 原始 Psum 输出接口

2026年11月3日起，cluster_top 移除 Requant，直接输出完整的 signed32 累加结果。本文与当前 RTL 是接口依据。

## 输出定义

- raw_psum[1023:0]：32 个物理 lane，每个 lane 为 32 bit。lane l 对应 raw_psum[32*l+:32]，按 signed32 解释。
- psum_valid[31:0]：每 bit 对应同编号 lane，仅在该 bit 为 1 的周期采样对应数据。允许多个归约组同时发布，最多 32 个 lane 有效。
- 输出无 ready、无反压。接收端必须能在有效周期接受数据；无效 lane 的 payload 不保证保持或为零。
- reset 异步清除有效位；复位期间 psum_valid=0。

raw_psum 是现有 tmp/Psum 存储的组合读取，psum_valid 使用已有 raw 发布寄存器。没有新增输出数据寄存器，也没有原 Requant 的额外 1T 延迟。下游应在 psum_valid 为 1 的周期采样，不能继续沿用旧 INT8 输出的延迟。

## 数值与物理布局

输出为位融合及所有 OS Tile 累加后的原始点积，未应用 multiplier、shift、zero point、round 或 INT8 saturation。输入数据存在量化零点时，raw 点积也未减去输入偏置，后处理由下游完成。

lane 布局保持现有归约树的物理组编号与 OC 对应关系。被屏蔽的 OC 或无贡献路径不产生 valid；高组、空洞和多组输出不压缩到低 lane。WS/单 Context 从 tmp 读取，OS>1 或多 Context AS 从对应 Context 的 Psum 读取。

内部 tmp/Psum 仍为 signed32。调用方应保证每次中间写入及最终结果都在 signed32 范围内。仿真中的溢出检查不表示硬件带饱和器或溢出标志。

## 删除的接口与逻辑

已移除 requant_cfg_i、requant_cfg_t、requant_data_o、requant_valid_o、ENABLE_REQUANT、REQUANT_CONTEXT_DEPTH、ClusterRequant 实例及其 RTL 文件。批次/AS Context 的 scale、shift、ZP 存储、有效位、选择逻辑、四组配置时钟和 32 组 INT8 输出时钟全部移除。

权重地址、ACT、tmp/Psum、归约、SRAM 常规访问和计算调度保留。Command 仍为 110 bit，cim_os_cnt/cim_ws_cnt/cim_as_cnt 各 9 bit，编码 1～511；MAX_CONTEXTS 和实际 buffer 深度限制继续生效，默认深度 16，默认 MAX_CONTEXTS=64。权重行地址仍为 8 bit。

## 编译与验证入口

从 vcs-rtl 运行 make run CASE=cluster_default，或 make run CASE=gemm_os1_ws32_as1_w8a16_raw。filelist 不再编译量化单元，原 Requant 用例和 scale/ZP reload 拒绝用例已从 cases.py、cases.mk 和 Makefile 入口删除。

TB 的独立数值模型通过公开 raw_psum/psum_valid 端口验证算术与时序。GEMM 结果 CSV 为 m,n,raw，Python 逐坐标对照 raw golden，拒绝重复或缺失结果。现有向量生成器可能同时生成历史量化辅助文件，当前 DUT 与数值判定不消费这些量化输出。

本地入口：python RTL/cluster/tb/py/run_sram_regression.py；--full 运行全部 raw/协议用例，--case 可选择一个或多个用例，--sim-dir 指定仓库外的快照目录。需要将 vlib、vlog、vsim 加入 PATH。

## 本轮验证

本地ModelSim的10个目标普通及SYNTHESIS条件编译通过。默认Cluster的200组配置、1368个case，以及输入重叠、OS255/256/511的36个边界场景、门控开关对照、空批次边界、常规SRAM和Context压力场景通过。7种GEMM的1504个signed32输出逐元素匹配。零count三个字段、Context超容量和SRAM写/计算冲突均按预期拒绝。未执行实际VCS或工艺综合/STA。

## 输入 Macro 和输出 channel 的位序

所有固定打包字段采用低编号在LSB侧的约定。LSB描述向量内的bit排列，不表示Macro编号必然等于ACT slot或最终输出组编号。

### Macro编号与控制字段

Macro编号m为0～7。常规SRAM访问使用macro_id={sram_macro_group,sram_bank_sel}，即macro_id=4*sram_macro_group+sram_bank_sel。{0,2'b00}选Macro0，{1,2'b11}选Macro7；sram_wrdata整条1024bit只写选中的Macro，不按8个Macro切分。计算时8个Macro共享cim_weight_raddr，分别从自己的SRAM读取该行。

- cim_macro_en_mask[m]对应Macro m，bit0是Macro0。
- cim_macro_oc_mask[4*m+c]对应Macro m的本地OC c，c为0～3。
- cim_act_slot_sel[3*m+:3]给出Macro m的ACT slot，最低3bit属于Macro0。slot是可配置路由，不固定等于m。

### ACT和权重的局部元素顺序

设权重精度为W bit，单Macro的K长度Kmacro=256/W。W2/W4/W8分别为128/64/32，对应可选ACT slot数2/4/8。

外部每拍act_data_i提供一条1024bit ACT Plane。第phase条Plane存放各ACT元素的第phase个4bit digit，phase0先到，对应ACT最低4bit；后续依次为bit[7:4]、[11:8]、[15:12]，按A精度取1/2/4条Plane。

Macro m令slot=cim_act_slot_sel[3*m+:3]，局部K元素j的ACT digit来自Plane[4*(slot*Kmacro+j)+:4]，进入SingleMacro.cim_idata[4*j+:4]。因此slot0从Plane最低位开始，j=0位于该slot最低4bit。每个Macro的四个OC复用同一份ACT。

每条Macro权重行按四个OC连续排列：OC0为sram_wrdata[255:0]，OC1为[511:256]，OC2为[767:512]，OC3为[1023:768]。OC c的K元素j存放在sram_wrdata[256*c+W*j+:W]，元素0位于该OC区域LSB。sram_wmask[c]对应同编号OC，1保持、0写入。

SingleMacro的四个局部phase结果同样按OC从低位排列：cim_odata[18*c+:18]。Cluster内部先按Macro编号拼接，每个Macro占72bit，Macro0位于macro_data[71:0]。

### 归约组到正式输出lane

归约仅合并同编号OC：组内各Macro的OC0相加，OC1相加，依此类推。不同OC不会互相归约。

令g=group_of(cim_reduce_split_mask,m)，则Macro m的本地OC c最终贡献到lane=4*g+c。正式端口为raw_psum[32*lane+:32]，对应有效位psum_valid[lane]。输出按物理归约组g、再按本地OC c递增排列；被禁用的物理组或OC保留原位置，不压缩有效channel。

- 全部独立（split=7'h7f）：g=m，Macro0/OC0→lane0→raw_psum[31:0]；Macro0/OC3→lane3→[127:96]；Macro1/OC0→lane4→[159:128]；Macro7/OC3→lane31→[1023:992]。
- 八Macro全归约（split=7'h00）：全部属于g=0，八个Macro的同编号OC求和后仅使用lane0～3，即raw_psum[127:0]。
- 两个四Macro组（split=7'h01）：Macro0～3→g0→lane0～3；Macro4～7→g1→lane4～7。若只启用高组，结果仍在raw_psum[255:128]、psum_valid[7:4]，不会移动到最低128bit。

lane是物理结果槽位，并不自动等于网络的全局输出channel编号。全局channel还取决于软件给各Macro/OC装载的权重及当前AS Context；AS的不同Context会在不同有效周期复用相同物理lane。
