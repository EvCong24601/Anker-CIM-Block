# Cluster 常规权重 SRAM 读写

单个 Cluster 有 8 个 Macro。每个 Macro 为 256 行 × 128 B，四个本地 OC 共用同一个 8-bit 行地址，每 OC 每行占 32 B。Cluster 总容量为 256 KiB。

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
| sram_rd_data | 输出 | 1024 | 选中 Macro 的完整 128 B 原始权重行 |
| sram_rd_valid | 输出 | 1 | 本次同步读响应有效，与锁存的 Macro 编号及读数据对齐 |

`macro_id={sram_macro_group,sram_bank_sel}=4*sram_macro_group+sram_bank_sel`。
group=0 选择 Macro0…3，group=1 选择 Macro4…7；bank_sel 不表示 Macro 内部另一个可寻址 bank。访问 Macro5、row12 时，group=1、bank_sel=01、row_addr=12。

本地 OC c 对应 `sram_wrdata[256*c+:256]` 和 `sram_rd_data[256*c+:256]`。`wmask=0000` 为整行全写，`1111` 全部保持，`0010` 只屏蔽 OC1。写掩码不影响原始权重读回，也与计算用 cim_macro_oc_mask 的有效位语义相互独立。

一次常规访问仅选中一个 Macro 的一行；128 B 不跨四个 Macro 分发。16 组 Cluster 端口由外部选择 Cluster，单 Cluster 内没有 cim_cluster_index。macro_group 不等同于归约树的 group_id。

## 当前参考模型时序

`MacroWeightSRAM`在上升沿采样读写请求。读请求为`sram_cs_en && !sram_wr_en`；同沿锁存响应Macro编号，SRAM数据沿后可见，`sram_rd_valid`沿后置1，没有额外数据流水。支持每拍一笔请求。

采样之后，输入可以切到下一Macro/行或改变CS、读写方向，当前有效响应保持到下一采样沿。下一沿若仍为读，则发布下一响应；若为空闲或写，则valid清零、数据输出0。reset异步清除valid并取消待响应数据，不清SRAM。

例如C0接受Macro0/row1，C0沿后返回该行且valid=1；C0到C1之间准备Macro1/row2，响应仍为Macro0；C1沿后才切换到Macro1。接收端在valid=1时取数，无响应反压。

CIM刷新在Macro接受输入的边沿同步读SRAM，同沿寄存ACT，下一沿捕获计算结果，保持1T/II1。SRAM访问时钟与计算时钟独立；常规读也必须打开访问时钟。实际SRAM IP替换须满足这个固定读时序。

常规访问与 CIM 计算分阶段使用同一 SRAM，无并发双端口能力。片选期间 cmd_ready_o 为零；若常规访问与有效 Command、活动计算批次重叠，仿真报告 CLUSTER_SRAM_PROTOCOL 错误，禁止将其当作静默仲裁。

有效写入使所选Macro的SRAM输出行标签失效；全屏蔽写及未片选写保持状态。常规读和CIM刷新均更新实际读出行号与valid；普通读过其他行后，下一次CIM须按目标地址重新判断刷新，不能沿用旧计算行。reset清标签，不清SRAM阵列。计算直接使用SRAM保持输出，不配置独立held_weight，也不经对外sram_rd_data返回路径取数。

Cluster 权重存储仅通过常规 WLC 接口访问：每次选择一个 Macro 的一行，写入/读回均为 128 B。TB 逐 Macro 写入并读回校验后，再开始计算。

## 回归和日志

从仓库根目录运行：

VCS 运行入口及各 case 的参数见 [vcs-rtl 使用说明](../vcs-rtl/README.md)。

仿真使用 [VCS case 入口](../vcs-rtl/README.md)，支持独立编译、数据生成、运行及结果检查。

VCS 从 vcs-rtl 目录执行 `make sram`；或在已完成编译后执行 `make sim PVALUE=+SRAM_RW_TEST`。专项成功标志为 `PASS sram_rw`。该专项不生成或覆盖默认计算 suite 的 split/operation CSV，不适用默认 make check。

用例覆盖全部 8×256 行、全部 16 种写掩码、0/1/127/255 边界及内部地址、其他 Macro/邻行/屏蔽 OC 保持、CS=0、读忽略掩码、连续写、复位保留、逐 Macro 写入并经常规口读回，以及四次真实 W4A4 计算检查写后 Hold 刷新。

所有测试在 case 开始打印 `[CASE_START] time=... ns suite=... description=...`，时间为仿真时间。Cluster case 还包含 cim_precision、sign、counts、split、EN、OC mask、slot、pattern、空拍和 seed；SRAM case 包含 Macro、行号、mask 和片选；SingleMacro 包含场景、精度、phase、刷新/复用等信息；归约树包含树配置和掩码。CMD_SEND/CMD_ACCEPT 日志继续保留。

TB 文件拆分和采样说明见 [Testbench 阅读指南](Testbench_Guide.md)。

同地址复用依赖SRAM输出在无新读期间保持稳定。常规读恰好读入下一计算地址时，可直接复用；新读取其他地址则覆盖保持行。有效写入后的旧读出不能视为新权重，必须先重新读取。1T/II1与常规口sram_rd_valid时序不变。
