# Macro ACT 按精度分区门控

SingleMacro保留512bit activation_in输入寄存边界，将其分成低128bit、中间128bit和高256bit三个独立时钟域。512bit数据容量、1T计算延迟、II=1及外部接口保持原定义。

## 位映射与请求

每次发射处理一个4bit ACT Slice，位数由权重精度决定：W2对应128个K元素、512bit；W4对应64个K元素、256bit；W8对应32个K元素、128bit。A4/A8/A16决定Slice数量，不改变单次请求的分区规则。

- activation_in[127:0]：所有有效W2/W4/W8请求捕获。
- activation_in[255:128]：仅有效W2/W4请求捕获。
- activation_in[511:256]：仅有效W2请求捕获。

请求有效条件沿用issue，即非复位、cim_ren有效且至少一个本地OC有效。无效、空闲或零OC mask时全部ACT区停止时钟并保持旧值；常规SRAM访问不触发ACT捕获。控制、SRAM及逐OC结果使用独立时钟域；权重由SRAM输出保持，行标签随访问域更新。

## 时序与精度切换

ICG请求由当前cim_precision解码，不使用上一笔请求的weight_mode_in。Cluster输入来自已寄存的packet与调度状态；ICG在输入采样沿之前的低电平窗口锁存请求。独立Macro实例仍按输入接口建立/保持要求提前驱动请求，不增加预接收周期。

在接受沿Cn，当前W模式所需全部ACT区与控制同沿捕获。Cn到Cn+1使用这些寄存值计算，Cn+1寄存结果并可同时接受下一笔。W8切回W2时三段在Cn共同更新，不能等旧weight_mode_in变成W2后才开启高位时钟。

关闭区保持旧内容，乘法路径仅访问当前模式所需范围。三个数据区均异步复位；USE_CLOCK_GATING=0时旁路ICG，但各区仍按同一捕获条件写入，保证与门控配置逐拍一致。

## 资源与功耗范围

每Macro增加三个ICG，8 Macro合计24个。activation_in仍为512×8=4096bit数据DFF；计入9bit count及唯一conv_mode后，默认整个Cluster声明级名义DFF按差量推导为33496bit，ICG锁存位为684，二者分开统计。

相对每次有效请求都打开512bit ACT时钟，W4仅打开256bit、W8仅打开128bit。这是ACT寄存器时钟负载的变化，不能直接等同于整个Macro的功耗降低比例。ICG自身面积、时钟树、乘加及SRAM保持输出活动需由综合及功耗工具评估。

## 验证

Macro测试覆盖全部49种有序精度切换，在权重刷新和Hold复用两条路径各执行一次，每组源/目的请求连续发射，共196笔定向请求。未使用高位使用随机非零扰动，数值与独立golden比较。

Macro和Cluster检查器在接受沿核对三个实际ACT时钟、捕获数据、关闭区保持及异步清零；整Cluster门控开关对照同时比较8 Macro完整activation_in。正常回归仍覆盖七精度、INT/UINT、OS/WS/AS、输入重叠、容量拒绝、SRAM和Requant。

主要实现：RTL/macro/rtl/SingleMacro.sv；Macro检查及场景在macro_scoreboard.svh与macro_regression.svh；Cluster检查在cluster_gate_checks.svh与cluster_gate_equivalence.svh。
