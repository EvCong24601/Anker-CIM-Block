# Weight Stationary 数值稀疏度测试

测试台：[tb_WeightStationary2cycle_Sparsity.sv](tb_WeightStationary2cycle_Sparsity.sv)。另一版本为 [Toggle TB](tb_WeightStationary2cycle_Toggle.sv)。

两者使用相同顶层名 `tb_WeightStationaryNetlist` 和 `dut` 层次，以保留原有 VCS/SDF/SAIF 配置。编译时用新文件替换原 Toggle TB，**不要把两个 TB 同时编译**。新文件保留原网表 include、DUT 实例、时钟及采样、SDF 反标、SAIF、VCD/FSDB、TRACE、SRAM 初始化、两拍流水和完整精度结果检查。

## 参数与运行

默认 W8A8、INT、WS=16、TOTAL_ACT=256；ACT 和 WGT 默认均为 50% sparsity。稀疏度支持 0～100 的整数百分比，包括 50/60/70/80/90。

```sh
# 同时设置 ACT 和 WGT 为 70% 零值
./simv +WS=16 +TOTAL_ACT=256 +SPARSITY_PCT=70 +SAIF=ws16_s70.saif -l ws16_s70.log

# 分别设置：ACT 80%，WGT 60%
./simv +WS=8 +ACT_SPARSITY_PCT=80 +WGT_SPARSITY_PCT=60 +SAIF=ws8_a80_w60.saif -l ws8_a80_w60.log

# 公共参数设为 70%，再单独覆盖 WGT 为 90%；与命令行参数排列顺序无关
./simv +SPARSITY_PCT=70 +WGT_SPARSITY_PCT=90
```

`SPARSITY_PCT` 为公共默认，`ACT_SPARSITY_PCT` / `WGT_SPARSITY_PCT` 分别覆盖。新 TB 不再提供翻转率控制，也不接受旧的 `ACT_TOGGLE_PCT`、`WGT_TOGGLE_PCT`、`STIM_MODE` 参数，避免误用旧运行参数。

当前包未包含原批量运行脚本。使用现有 VCS 可执行文件并传入对应参数，例如从归档根目录运行：

```sh
mkdir -p build/ws32_sparsity/pct70
./simv_sparsity +WS=32 +TOTAL_ACT=256 +PRECISION=5 +SIGNED=1 +SEED=20261114 \
  +CLK_PERIOD_NS=3.906 +SPARSITY_PCT=70 \
  +SAIF=build/ws32_sparsity/pct70/activity.saif -l build/ws32_sparsity/pct70/sim.log
```

`simv_sparsity` 需先用本 TB 和实际网表/工艺模型编译，并定义 `SDF_FILE`。
同名输出会被新实验覆盖，需要保留历史数据时使用新的输出目录。
已归档实测结果为 [../build/ws32_sparsity/](../build/ws32_sparsity/) 下 WS=32 的 50/70/90/100%，
对应功耗报告位于 [../ptpx/](../ptpx/)。60%、80% 为 TB 支持的参数，当前包没有这两档实测结果。

## 稀疏度口径

**sparsity = 完整数值为 0 的元素数 / 有效元素总数**，不是二进制位中 0 的比例，也不是相邻拍翻转率。

| W 模式 | 每个完整 ACT 向量的元素数（4 个 OC 共用） | 每行 WGT 的元素数（4 个 OC 合计） |
|---|---:|---:|
| W2 | 128 | 512 |
| W4 | 64 | 256 |
| W8 | 32 | 128 |

ACT 先生成完整 A4/A8/A16 值并设置零元素，再拆分为每拍 4bit phase。一个非零 A8 值可能有零 nibble，不会因此计成零 ACT。无效的高位 `cim_idata` 保持 0 且不计入稀疏度分母。WGT 按 W2/W4/W8 的完整数值设置零元素，统计范围为整行，未强制每个 OC 的零数量相同。

非零元素从当前位宽的所有非零编码中随机抽样；INT 按二补码解释，UINT 按无符号解释。抽样排除 0，避免额外增加稀疏度。0% 为全部非零，100% 为全部零；这与旧的独立均匀随机模式不同。

每条流先累积 `元素数 × sparsity_pct`，取整确定本次零元素个数，余数留到下一向量/行，再随机选择互不重复的位置置零。前 K 个向量/行的总零数为：

```text
floor(K × 每个向量或行的元素数 × sparsity_pct / 100)
```

因此累计误差小于一个元素，不要求每个小向量都恰好等于目标比例。所有样本（包括第一个）均计数。新样本重新随机生成，不控制其与前一时刻之间的翻转率。

ACT/WGT 使用独立随机流。相同 seed、精度及对应稀疏度下，不同 WS 的 ACT 序列和权重行序列相同。WGT 只在刷新时换行，复用拍保持；**WS 不会将 WGT 稀疏度除以 WS**。由于每行驻留相同拍数，按刷新和按有效发射拍重复计数的 WGT 零元素比例相同。

沿用不回绕权重行的约束：`TOTAL_ACT × phases / WS <= 256`。超出直接报错，避免重复 SRAM 行改变累计稀疏度预算。默认 W8A8、TOTAL_ACT=256 可运行全部四档 WS。WS 仍以 phase 发射拍计数；A16 的四个 phase 必须位于同一 WS 窗口，所以不支持 WS=2。

## 统计与验证

日志新增：

- `WS_SPARSITY ACT`：从实际接受的 phase 输入重组完整向量后，统计向量数、元素数、零数和实测稀疏度。
- `WS_SPARSITY WGT_REFRESH`：按实际接受请求的刷新地址，统计预先写入 SRAM 的对应行中的元素数、零数和实测稀疏度。这是预期权重数据的逻辑统计，不是对门级内部节点的直接采样。

每个完整 ACT / 每次 WGT 刷新都会检查累计零元素预算，同时保留原有每 phase 点积、完整向量点积、两拍延迟、mask、WS 节奏和流水排空检查。

当前包已移除原本地回归脚本和功能单元模型；门级环境准备及整体目录见 [归档说明](../README.md)。
