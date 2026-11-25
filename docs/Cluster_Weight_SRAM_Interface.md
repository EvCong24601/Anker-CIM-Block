# Cluster 常规权重 SRAM 读写

单个 Cluster 有 8 个 Macro。每个 Macro 的逻辑容量为 256 行 × 128 B，由两块 256 行 × 64 B 的单端口 SRAM 承载。四个本地 OC 共用同一个 8-bit 行地址，每 OC 每行占 32 B。Cluster 总容量为 256 KiB。

## 端口与寻址

方向以 Cluster 为视角，WLC 驱动所有输入。

| 信号 | 方向 | 位宽 | 定义 |
|---|---|---:|---|
| sram_cs_en | 输入 | 1 | 1 发起常规访问，0 不访问 |
| sram_wr_en | 输入 | 1 | 1 写，0 读；由片选限定 |
| sram_macro_group | 输入 | 1 | Macro 编号 bit2 |
| sram_bank_sel | 输入 | 2 | Macro 编号 bit1:0 |
| sram_row_addr | 输入 | 8 | 选中 Macro 的行号 0…255，四个 OC 共用 |
| sram_wmask | 输入 | 4 | bit c 为 1 时屏蔽 OC c 的 32 B 写入，为 0 时允许写入 |
| sram_wrdata | 输入 | 1024 | 选中 Macro 的完整 128 B 权重行 |
| rstn_config | 输入 | 1 | 低有效异步复位：清零顶层三项广播配置寄存器和每个 Macro 的 64-bit 修复寄存器；独立于 `reset_n` |
| timing_config_i | 输入 | 8 | 广播到全部 16 块 SRAM 的时序配置；顶层上升沿采样，复位为 0 |
| waen_i | 输入 | 1 | 广播到全部 16 块 SRAM 的写辅助使能；顶层上升沿采样，复位为 0 |
| raen_i | 输入 | 1 | 广播到全部 16 块 SRAM 的读辅助使能；顶层上升沿采样，复位为 0 |
| sram_rd_data | 输出 | 1024 | 选中 Macro 的完整 128 B 原始权重行 |
| sram_rd_valid | 输出 | 1 | 本次同步读响应有效，与锁存的 Macro 编号及读数据对齐 |

`macro_id={sram_macro_group,sram_bank_sel}=4*sram_macro_group+sram_bank_sel`。
三项广播配置每个 Cluster 时钟沿更新一次，寄存器输出同时送到全部 Macro 的两块 SRAM，不随 `macro_id` 切换。若实体 SRAM 在访问时钟沿采样这些引脚，上层应至少提前一个 Cluster 时钟周期设置配置，并用实际宏时序库检查寄存器到 SRAM 引脚的建立、保持时序及广播扇出。
`rstn_config` 只复位配置存储，不复位 MBIST 控制器及完成状态。释放后，广播配置继续逐拍采样；被 `mbist_macro_id_i` 选中的 Macro 也会继续采样当前修复码。
group=0 选择 Macro0…3，group=1 选择 Macro4…7；bank_sel 不表示 Macro 内部另一个可寻址 bank。访问 Macro5、row12 时，group=1、bank_sel=01、row_addr=12。

本地 OC c 对应 `sram_wrdata[256*c+:256]` 和 `sram_rd_data[256*c+:256]`。`wmask=0000` 为整行全写，`1111` 全部保持，`1101` 只写 OC1。普通读始终读取两块的完整数据，与 `sram_wmask` 和计算用 `cim_macro_oc_mask` 无关。

一次常规访问仅选中一个 Macro 的一行；128 B 不跨四个 Macro 分发。16 组 Cluster 端口由外部选择 Cluster，单 Cluster 内没有 cim_cluster_index。macro_group 不等同于归约树的 group_id。

## 当前参考模型时序

`MacroWeightSRAM`在上升沿采样读写请求。读请求为`sram_cs_en && !sram_wr_en`；同沿锁存响应Macro编号，SRAM数据沿后可见，`sram_rd_valid`沿后置1，没有额外数据流水。支持每拍一笔请求。

采样之后，输入可以切到下一Macro/行或改变CS、读写方向，当前有效响应保持到下一采样沿。下一沿若仍为读，则发布下一响应；若为空闲或写，则valid清零、数据输出0。低有效异步复位 `reset_n` 清除响应valid及标签，不清SRAM。复位不参与端口/使能的组合表达式；`MacroWeightSRAM` 是无复位wrapper，不含复位端口或访问保护条件。上层必须在复位期间将Cluster的 `sram_cs_en` 置0；直接使用SingleMacro时须将 `cim_ren`、`sram_wen`、`sram_ren` 置0。wrapper只按时钟和功能使能读写；访问无效时阵列及内部读出保持值保持，复位本身不会阻止访问。

例如C0接受Macro0/row1，C0沿后返回该行且valid=1；C0到C1之间准备Macro1/row2，响应仍为Macro0；C1沿后才切换到Macro1。接收端在valid=1时取数，无响应反压。

CIM 刷新在 Macro 接受输入的 C0 沿同步读 SRAM 并寄存 ACT，C1 保存 CSA 中间结果，C2 保存 CPA 与符号修正后的结果，两拍延迟、II=1。SRAM访问时钟与计算时钟独立；常规读也必须打开访问时钟。实际SRAM IP替换须满足这个固定读时序。

常规访问与 CIM 计算分阶段使用同一 SRAM，无并发双端口能力。片选期间 cmd_ready_o 为零；若常规访问与有效 Command、活动计算批次重叠，仿真报告 CLUSTER_SRAM_PROTOCOL 错误，禁止将其当作静默仲裁。

有效写入使所选 Macro 的 SRAM 输出行标签失效，全屏蔽写及未片选写保持状态。常规读更新行标签并标记四个 OC 已读。CIM 刷新按 `cim_macro_oc_mask` 更新 SRAM 读出，只选中有读取请求的 512-bit 块。行地址相同但有 OC 尚未读出时，Macro 在计算发射沿补读缺少的 OC。`reset_n=0` 清标签，不清 SRAM 阵列。计算直接使用 SRAM 保持输出。

Cluster 权重存储仅通过常规 WLC 接口访问：每次选择一个 Macro 的一行，写入/读回均为 128 B。TB 逐 Macro 写入并读回校验后，再开始计算。

## 回归和日志

从仓库根目录运行：

VCS 运行入口及各 case 的参数见 [vcs-rtl 使用说明](../vcs-rtl/README.md)。

仿真使用 [VCS case 入口](../vcs-rtl/README.md)，支持独立编译、数据生成、运行及结果检查。

VCS 从 vcs-rtl 目录执行 `make sram`；或在已完成编译后执行 `make sim PVALUE=+SRAM_RW_TEST`。专项成功标志为 `PASS sram_rw`。该专项不生成或覆盖默认计算 suite 的 split/operation CSV，不适用默认 make check。

用例覆盖全部 8×256 行、全部 16 种写掩码、0/1/127/255 边界及内部地址、其他 Macro/邻行/屏蔽 OC 保持、CS=0、读忽略掩码、连续写、复位保留，以及四次真实 W4A4 计算检查写后 Hold 刷新。

所有测试在 case 开始打印 `[CASE_START] time=... ns suite=... description=...`，时间为仿真时间。Cluster case 还包含 cim_precision、sign、counts、split、EN、OC mask、slot、pattern、空拍和 seed；SRAM case 包含 Macro、行号、mask 和片选；SingleMacro 包含场景、精度、phase、刷新/复用等信息；归约树包含树配置和掩码。CMD_SEND/CMD_ACCEPT 日志继续保留。

TB 文件拆分和采样说明见 [Testbench 阅读指南](Testbench_Guide.md)。

同地址复用依赖 SRAM 保持未读取的输出切片。常规读恰好读入下一计算地址时可直接复用。CIM 换行后从新行重新记录已读 OC。权重补读、刷新和复用均使用同一个发射沿，计算延迟为两拍、II=1。常规口 `sram_rd_valid` 在同步读请求采样沿后生效。
