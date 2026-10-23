# Cluster 常规权重 SRAM 读写

单个 Cluster 有 8 个 Macro。每个 Macro 为 256 行 × 128 B，四个本地 OC 共用同一个 8-bit 行地址，每 OC 每行占 32 B。Cluster 总容量为 256 KiB。

## 端口与寻址

方向以 Cluster 为视角，WLC 驱动所有输入。

| 信号 | 方向 | 位宽 | 定义 |
|---|---|---:|---|
| cim_cs_en | 输入 | 1 | 1 发起常规访问，0 不访问 |
| cim_wr_en | 输入 | 1 | 1 写，0 读；由片选限定 |
| cim_macro_group | 输入 | 1 | Macro 编号 bit2 |
| cim_bank_sel | 输入 | 2 | Macro 编号 bit1:0 |
| cim_row_addr | 输入 | 8 | 选中 Macro 的行号 0…255，四个 OC 共用 |
| cim_wmask | 输入 | 4 | bit c 为 1 时屏蔽 OC c 的 32 B 写入，为 0 时允许写入 |
| cim_wrdata | 输入 | 1024 | 选中 Macro 的完整 128 B 权重行 |
| cim_rd_data | 输出 | 1024 | 选中 Macro 的完整 128 B 原始权重行 |

`macro_id={cim_macro_group,cim_bank_sel}=4*cim_macro_group+cim_bank_sel`。
group=0 选择 Macro0…3，group=1 选择 Macro4…7；bank_sel 不表示 Macro 内部另一个可寻址 bank。访问 Macro5、row12 时，group=1、bank_sel=01、row_addr=12。

本地 OC c 对应 `cim_wrdata[256*c+:256]` 和 `cim_rd_data[256*c+:256]`。`wmask=0000` 为整行全写，`1111` 全部保持，`0010` 只屏蔽 OC1。写掩码不影响原始权重读回，也与计算用 macro_oc_mask 的有效位语义相互独立。

一次常规访问仅选中一个 Macro 的一行；128 B 不跨四个 Macro 分发。16 组 Cluster 端口由外部选择 Cluster，单 Cluster 内没有 cim_cluster_index。macro_group 不等同于归约树的 group_id。

## 当前参考模型时序

`MacroWeightSRAM` 使用上升沿按 OC 写入、使能组合读。参考 adapter 在片选读期间组合返回整行，未片选、写入期间及 reset 时 cim_rd_data 为零；支持相邻上升沿连续写，以及读地址连续切换。这是当前仿真模型的明确行为，物理 SRAM 的采样、读返回延迟及背靠背访问协议仍待集成冻结，不据此宣称物理 IP 为零拍读。

常规访问与 CIM 计算、TB preload 分阶段使用同一 SRAM，无并发双端口能力。片选期间 cmd_ready_o 为零；若常规访问与有效 Command、活动计算批次或 preload 重叠，仿真报告 CLUSTER_SRAM_PROTOCOL 错误，禁止将其当作静默仲裁。

有效写入使所选 Macro 的 Cluster Hold 跟踪和 SingleMacro Hold 同时失效，下次计算刷新该行。全屏蔽写入、未片选写入及常规读不改变 Hold 有效状态。reset 清控制与 Hold，不清 SRAM。CIM 计算继续使用广播的 weight_cim_raddr，不经 cim_rd_data 返回原始权重。

weight_wen_i/weight_waddr_i/weight_wdata_i 保留为 TB preload 验证辅助接口，数据宽度为八个独立 128 B 行，共 8192 bit；其写掩码内部固定为 0000。它们与 128 B WLC 总线访问同一份存储。

## 回归和日志

从仓库根目录运行：

```text
python RTL/cluster/tb/py/run_sram_regression.py --full
```

入口需要 ModelSim 的 vlib/vlog/vsim，仿真源码、日志及 SHA256 清单保存在仓库同级 cluster_tb_work/local_sim/sram_rw；可用 --sim-dir 指定仓库外目录。默认运行 SRAM 正向测试、两种冲突负向测试，以及 SingleMacro 门控开/关回归和 15 类协议负向 case（含部分初始化行的刷新/复用）；--full 追加默认 Cluster、归约树、OC merge、ACT 容量、完整 ACT、混合 Context 和大 Context/Psum 容量回归。冲突测试必须命中指定协议诊断，正向测试要求 PASS 且没有 Fatal/Error。

VCS 从 vcs-rtl 目录执行 `make sram`；或在已完成编译后执行 `make sim PVALUE=+SRAM_RW_TEST`。专项成功标志为 `PASS sram_rw`。该专项不生成或覆盖默认计算 suite 的 split/operation CSV，不适用默认 make check。

用例覆盖全部 8×256 行、全部 16 种写掩码、0/1/127/255 边界及内部地址、其他 Macro/邻行/屏蔽 OC 保持、CS=0、读忽略掩码、连续写、复位保留、preload 与常规口共享存储，以及三次真实 W4A4 计算检查写后 Hold 刷新。

所有测试在 case 开始打印 `[CASE_START] time=... ns suite=... description=...`，时间为仿真时间。Cluster case 还包含 precision、sign、counts、split、EN、OC mask、slot、pattern、空拍和 seed；SRAM case 包含 Macro、行号、mask 和片选；SingleMacro 包含场景、精度、phase、刷新/复用等信息；归约树包含树配置和掩码。CMD_SEND/CMD_ACCEPT 日志继续保留。

TB 文件拆分和采样说明见 [Testbench 阅读指南](Testbench_Guide.md)。
