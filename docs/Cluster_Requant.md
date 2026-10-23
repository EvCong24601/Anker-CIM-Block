# Per-tensor Requant

Cluster保留raw signed32输出，新增signed INT8输出。Per-tensor仅指multiplier/shift共用；INT32 zp按weight输出channel配置，输入补偿已由参数生成端合入zp。Cluster直接对raw Psum执行Requant。数据通路为：

```text
tmp / Psum 最终运算
      ↓ Ck
raw_data 输出寄存器（32 × 32 bit） / out_valid_o
      ↓ 单级组合 ClusterRequant
      ↓ C(k+1)
requant_data_o 输出寄存器（32 × 8 bit） / requant_valid_o
```

量化 valid 严格比对应 raw valid 晚一拍。Requant 算术内部无流水寄存器，INT8 输出寄存器按 lane 独立更新，无 valid 时保持旧数据；复位清零数据和 valid，取消待量化结果。不同归约树终点保持各自的发布时序，不做向量收集。没有 ready/反压，接收端须始终可接收。

## 数值契约

`q[n]=clip_INT8(round(Psum[n]×multiplier×2^shift)+zp[n])`。

- `Psum`、`multiplier`、`zp` 均为 signed INT32，multiplier 没有隐含 Q31 缩放。
- `shift` 为 signed INT10，本阶段有效配置为 −31～31；大 shift 的完整范围处理暂未实现。
- 最近整数舍入，恰好半整数远离零；zp 在舍入之后相加。
- signed64 保留完整乘积，signed96 组合中间值容纳有效范围内的左移和 zp 加法。只在最后裁剪到 −128～127，不能在加 zp 前提前裁剪。
- 例如 `Psum=1, multiplier=1, shift=31, zp=-2147483648` 输出0；`Psum=-1, multiplier=1, shift=-1, zp=1` 也输出0。

仅对完成全部 slice 和 OS Tile 的最终 raw 结果量化一次。Requant 不改动 tmp/Psum 历史。

## 参数加载

`cluster_pkg.sv`使用独立1067-bit `requant_cfg_t`：mode1+multiplier32+shift10+32×32bit zp。lane l的zp位于`requant_zp[32*l+:32]`，按signed INT32解释。配置通过`requant_cfg_i`输入，107-bit compute descriptor不变。

`requant_mode=0` 表示per-tensor multiplier/shift；mode=1的per-channel scale暂不支持。zp始终是per-channel输出域zero-point，不由weight采用per-tensor/per-channel来决定其接口粒度。不同通道可以配置相同值。默认 `REQUANT_CONTEXT_DEPTH=1`，在batch首Command锁存所有参数，WS中同一weight channel跨ACT行复用配置。

AS可设置`REQUANT_CONTEXT_DEPTH>1`和`REQUANT_CONTEXT_LANES`（1～32）。首K Tile各Context Command加载其低lane zp；公共multiplier/shift只在batch首命令锁存。后续K Tile重复提交的Context zp必须一致。最终raw按内部Context标签选择参数，下一拍锁存INT8。OS2/AS4根归约使用depth=4、lanes=4：保存16个zp共512bit，每拍读当前Context的4项。

最后 raw 发布后一拍，可以同时捕获该结果的 INT8 值并接受下一 batch 的配置：输出寄存器使用沿前旧参数，新参数在沿后生效。INT8 无效 lane 的寄存器不会因配置变化而改变。复位配置为 multiplier=1、shift=0、zp=0。

当前仿真拒绝未知参数、per-channel模式和范围外shift；这些是配置契约检查，并非运行期错误上报端口。`ClusterRequant.sv` 本身是无时钟的组合功能模块；batch配置和输出寄存器位于 `cluster_dut_adapter.sv`。

## 参数生成与输入offset融合

输入offset补偿已合入参数生成端提供的逐通道INT32 zp。两个GEMM先计算原始实数矩阵乘积，再做校准；对对称weight，例如生成 `zp[n]=output_zp_reference[n]+round((-ACT_zp×sum(Wq[:,n]))×scale)`，RTL只读取生成后的`requant_zp.hex`。

硬件golden严格按本接口的“raw缩放舍入后加zp”生成。Python另外保存中心化数学参考，记录定点折算与舍入差异；不能将两种运算顺序混为同一参考。RTL与本接口整数golden须逐元素完全一致。`ClusterRequant`负责raw Psum的乘法、缩放、舍入、加zp及clip；adapter负责Context选择和输出寄存器。

## 测试

- `tb_ClusterRequant.sv`：无时钟组合单元测试，使用 `requant_vectors.py` 生成9,611个Python任意精度整数golden向量，32 lane共307,552次数值比较，包含正负极值、舍入边界、zp抵消、clip边界与固定种子随机向量。
- `include/cluster_requant_cases.svh`：168个集成case，覆盖7精度、signed/unsigned、OS1/2、Single/WS/AS、命令空拍及8种参数profile。原有所有计算suite也逐lane检查量化数值、延迟、保持及结果数，包括混合树、OC mask、AS64和OS255。
- 独立边界case：在上一batch最后量化捕获沿加载下一batch参数，检查旧结果用旧参数、新结果用新参数及跨配置保持。
- 独立reset case：在raw发布后、量化寄存前复位，检查取消待输出结果并清零寄存器。
- 4个配置负向case：per-channel、shift低于/高于当前范围、未知参数，必须捕获精确诊断。
- `tb_Cluster_GEMM_OS1_WS32.sv`：单Cluster分两批N8计算M32/K128/N16的W8A16 WS32矩阵，验证已合入输入补偿的逐通道zp、权重地址0x40/0x41、512个raw和512个INT8元素。详见 [GEMM说明](Cluster_GEMM_WS32.md)。
- `tb_Cluster_GEMM_OS2_AS4.sv`：单Cluster八Macro全归约，M32/K512/N16、OS2/AS4/WS1，检查512个raw、512个INT8、4096次Psum历史更新，以及Context容量、跨K Tile zp不一致的精确负向诊断。详见 [AS4说明](Cluster_GEMM_OS2_AS4.md)。

每个case开始打印英文描述与时间戳。运行全部测试：

```text
python RTL/cluster/tb/py/run_sram_regression.py --full
```

独立生成单元向量后，可使用ModelSim/VCS手动编译文件列表并选择 `tb_ClusterRequant` 顶层，传入 `+REQUANT_VECTORS=绝对路径`。Cluster专项使用 `+REQUANT_TEST`、`+REQUANT_BOUNDARY_TEST`、`+REQUANT_RESET_TEST`。

本次为功能仿真实现；组合乘法、缩放、舍入与裁剪的时序未经过综合/STA签核。
