# Cluster 验证与边界问题

当前生产RTL及TB以`fix_empty_int10_sources.sha256`标识，完整回归见`fix_empty_int10_validation.log`。十轮调查的原始证据保留在`ten_round_*`日志中；这些快照不能代替当前源码测试。

## 空批次与 INT10 的当前行为

空有效mask的issue不传播下游valid标签，从而不会使用下一批次的mask错误开启tmp时钟。全OC屏蔽与父节点屏蔽均验证七种精度；恢复旧标签行为的隔离副本必须触发无消费开钟检查。有效输出与ready时序不变。

Requant支持完整signed INT10范围−512～511。大正shift按非零乘积的符号精确饱和，零乘积仍加入ZP；右移64位及以上舍入为0，右移63位的半值保留。公式、输出寄存器及1T量化延迟不变。范围依据及测试见[Requant](Cluster_Requant.md)。

当前全量回归为133个suite（43正向、90预期拒绝），包含17908个Python整数向量、512个四通道向量和77组完整shift Context测试。详细范围见[验证清单](Cluster_Verification.md)。功能仿真不等同于综合/STA或对所有输入的形式证明。

## 仍待处理

### Psum 中间溢出策略 TBD

W8A16、signed、8 Macro归约、OS5，weight=127、ACT=32767、每Tile K256，数学结果5326603520；signed32存储截断后为1031636224。multiplier=1、shift=−26、ZP=0时，实际INT8为15，宽位参考为79，最终范围检查未报错。每次中间存储均须满足signed32范围，不能仅约束最终值。当前修复不改变此TBD。

### 未知 result mask 的协议检查遗漏

`SingleMacro.sv`的unknown compute input检查未包含`cim_result_mask`。X/Z result mask可能未被拒绝，valid有效而数据保持旧值。这是非法控制输入的诊断缺口；已知合法输入下的行为不能据此判为错误。当前修复不改变该检查。

两项问题的复现记录分别见`ten_round_targeted.log`、`ten_round_depth_and_unknown.log`。源码和日志位于`RTL/cluster/tb/log/`所记录的相应快照。
