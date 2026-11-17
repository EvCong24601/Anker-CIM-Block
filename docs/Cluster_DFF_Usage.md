# Cluster 三通道改版前的声明级资源口径

本页及同名 CSV 对应 2026 年 11 月 3 日的实现。三通道调度版需要重新统计控制状态。

2026年11月3日移除Requant后的默认逻辑DFF名义量为28159bit。从9bit count版本33496bit减去AS参数表4752bit、批次配置297bit、INT8输出及valid共288bit推导；尚未重新运行全量资源展开、工艺综合或STA，不表示综合后单元数或面积。

Cluster_DFF_Usage.csv 对应该历史实现，尚未按当前两拍 Macro、三通道和51 bit配置流水重新展开。raw输出数据为现有tmp/Psum的组合读取，未新增数据寄存器；已有raw valid提供psum_valid。

删除32个INT8输出ICG和4个参数配置ICG后，默认ICG锁存位为648（此前684）。权重地址的两个时钟域保留。SRAM权重阵列2097152bit和SRAM读出保持模型8192bit另列。

默认OUTPUT_PSUM_DEPTH=16、MAX_CONTEXTS=64。参数变化后须按声明重新统计；历史Word和资源日志中的含Requant总量不能直接用于当前RTL。接口见[raw输出契约](Cluster_Raw_Output.md)。
