# ACT / WGT 翻转率控制

实现文件：[tb_WeightStationary2cycle_Toggle.sv](tb_WeightStationary2cycle_Toggle.sv)。保留现有网表 include、DUT 实例、SDF、时钟、SAIF 和结果检查逻辑。

## 使用

在原有 VCS 运行参数后增加：

```sh
+STIM_MODE=toggle +ACT_TOGGLE_PCT=10 +WGT_TOGGLE_PCT=20
```

默认 `STIM_MODE=toggle`、ACT/WGT 均为 50%。两种百分比独立配置，支持整数 0～100（包括 5、10、20、50）。0% 表示首次随机取值后保持，100% 表示每次更新全部取反。

`+STIM_MODE=random` 恢复原先独立随机激励及原有 ACT digest 算法，此时忽略翻转率设置。controlled 50% 与独立随机模式的每次翻转数分布不同，适合分别作对照。

当前包仅保留 TB，未包含原批量运行脚本。将上述 plusarg 传入实际 VCS 可执行文件，例如从归档根目录运行：

```sh
mkdir -p build/ws32_toggle/pct10
./simv_toggle +WS=32 +TOTAL_ACT=256 +PRECISION=5 +SIGNED=1 +SEED=20261114 \
  +CLK_PERIOD_NS=3.906 +STIM_MODE=toggle +ACT_TOGGLE_PCT=10 +WGT_TOGGLE_PCT=10 \
  +SAIF=build/ws32_toggle/pct10/activity.saif -l build/ws32_toggle/pct10/sim.log
```

`simv_toggle` 需先用本 TB 和实际网表/工艺模型编译，并定义 `SDF_FILE`。
同名输出会被新实验覆盖，需要保留历史数据时使用新的输出目录。
现有实测结果位于 [../build/ws32_toggle/](../build/ws32_toggle/)，包含 WS=32 的 5/10/20/50% 四档；
对应功耗报告位于 [../ptpx/](../ptpx/)。支持更多参数组合不表示归档已包含其实际结果。
两个 TB 顶层同名，编译时只选择其中一个。详见 [归档说明](../README.md)。

## 定义与生成

翻转率为相邻有效样本的 Hamming distance / 有效位数，包含 0→1 与 1→0。首个随机样本没有前驱，不计入翻转分母；其值计入 ones 统计。初始化、复位和排空不计入这些输入统计。

| 对象 | 有效位宽 | 一次更新 |
|---|---:|---|
| ACT，W2 | 512 | 每次 phase 发射 |
| ACT，W4 | 256 | 每次 phase 发射 |
| ACT，W8 | 128 | 每次 phase 发射 |
| WGT | 1024 | 刷新时选择下一 SRAM 行 |

ACT 的高位无效输入保持 0，不计分母。ACT 按实际端口顺序 `A0.low → A0.high → A1.low → A1.high …` 生成，跨 phase、跨完整向量和跨 WS 窗口连续控制。先生成一个向量的所有 phase 并重组 `full_act`，保证完整精度 golden 检查仍独立计算点积。驱动端口时整段一次赋值。

每条流有独立的 PRNG 状态和余数。首次样本随机生成；后续更新：

```text
budget += width * pct
k = budget / 100
budget %= 100
next = previous XOR 随机选出的 k 个互不重复的 bit
```

使用部分 Fisher–Yates 选择不同 bit。每次更新精确翻转 k 位；累计实际翻转数等于 `floor(更新次数 × width × pct / 100)`，与理想累计值误差小于 1 bit。初始样本随机、对称 XOR，不强制每个样本的 1 占比精确为 50%；低翻转率或短测试尤其需要查看实测 `ones_pct`。该模型控制端口时序相关性，不等同于特定网络数据分布或内部节点翻转率。

同 seed / 精度 / ACT 百分比 / 模式下，不同 WS 的 ACT 序列相同；WGT 使用独立随机流，权重行序列不受 ACT 参数影响。WGT 在初始化时生成并写入 SRAM，计算时保持 SRAM 输出至下一刷新，不在复用拍重新生成权重。

受 SRAM 256 行容量限制，toggle 模式要求 `TOTAL_ACT × phases / WS <= 256`，超出直接报错，避免地址回绕产生不受控翻转。默认 W8A8、TOTAL_ACT=256 时 WS=2/8/16/32 均满足。random 模式保留原地址回绕行为。

## 日志与校验

- `WS_TOGGLE ACT`：有效输入端口逐次采样，输出样本数、有效位宽、翻转数、翻转机会数、实测百分比和 1 占比。
- `WS_TOGGLE WGT_REFRESH`：按接受请求时的地址，读取 TB 已写入 SRAM 的对应权重行，统计相邻刷新之间的翻转。此为预期 SRAM 读出数据的逻辑统计，不探测 DUT 内部物理节点，也不包含地址或控制信号。
- `WS_TOGGLE WGT_PER_ISSUE`：把同一权重翻转数除以 `1024 × (总发射数−1)`，计入复用拍的零翻转。

若有 N 次发射、M 次刷新，WGT 的两个分母分别为 `1024×(M−1)` 和 `1024×(N−1)`。后者约等于刷新翻转率 / WS，有限样本下应使用日志的精确结果。只有一次刷新时没有刷新间隔，打印 opportunities=0、pct=0，不能解释为完成了目标翻转率测量。

监视器独立累计实际采样差分，结束时校验样本数和累计精确预算。原有两拍延迟、每 phase 输出、完整向量点积、WS 刷新复用及排空检查保留。SAIF 仍沿用原窗口，包含流水填充/排空；输入逻辑翻转统计与整个 SAIF 窗口不是同一分母。

## 当前归档范围

原本地 Python 回归脚本和功能模型已经移出本包，当前只提供门级 TB、参数说明以及实际 VCS/PTPX 结果。
测量方法、网表准备和外部依赖见 [归档说明](../README.md)。
