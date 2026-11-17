# Cluster 当前 raw GEMM 验证

GEMM 通过单个 Cluster 的常规 SRAM 接口逐 Macro 写入并读回权重，再通过独立 cmd、weight、ACT 通道计算。正式输出为 signed32 raw_psum 和逐 lane psum_valid，RTL 不执行量化、零点补偿、舍入或 INT8 饱和。

`X[M,K] × W[K,N]` 的整数点积与独立 Python golden 逐坐标精确一致，并检查缺失/重复输出、物理 lane、mask 和采样沿。通过用例不代表低比特模型的任务精度或物理时序签核。

## 当前用例

- `gemm_os1_ws32_as1_w8a16_raw`：WS32，M32/K128/N16。
- `gemm_os2_ws1_as4_w8a16_raw`：OS2/AS4，M32/K512/N16。
- `gemm_os1_ws1_as8_w8a16_raw`：AS8，M8/K256/N32。
- `gemm_os1_ws8_as1_w4a16_high_group_raw`：W4 高位置归约组。
- `gemm_os1_ws8_as1_w2a8_high_group_raw`：W2 高位置归约组。
- `gemm_os1_ws8_as1_w4a16_n6_tail_raw`：N6 尾部及 OC 空洞。
- `gemm_os1_ws12_as1_w4a16_round_clip_raw`：保留原数据集名称的整数 raw 测试；名称不表示当前硬件存在 round/clip。

当前 case 名和参数以 `vcs-rtl/cases.py` 为准。旧 `_tensor`/`_channel` 量化 case 及 Requant 专项已从运行入口移除；生成器中保留的量化辅助文件不表示 RTL 有对应端口。

## 握手与拍点

每任务接收一次102 bit命令。地址总数为 OS×AS，ACT plane 总数为 OS×WS×P，P=A位宽/4。已接收任务可缓存或同沿直通所需操作数；地址迟到不阻塞已在途结果。

每笔 issue 经输入、CSA、Macro 结果三个寄存边界，延迟两拍。按 split 结构，Reduce-1/2、4、8 的 tmp 写入为 issue+3/+4/+5；OS/AS 使用 Psum 时再晚一拍。最终值写入沿后发布 valid，下游下一沿采样。绝对周期取决于真实输入握手，不再沿用旧 Command+A0 包的 C35～C38 等公式。

## 验证记录

2026-11-17 的 `path_class_20261117_full` 回归记录七组 GEMM 共1,504个 signed32 元素全部匹配。模型为 CSA 数学 golden，未执行固定工艺 CSA 门级仿真、综合或 STA。当前文档整理仅重新运行三通道及 TIMING_FIGURE 定向测试，没有重跑七组 GEMM。

从 `vcs-rtl` 运行 `make gemm-regression`，或使用本地回归脚本选择上述 case。正式输出及 lane 布局见[接口契约](Cluster_Raw_Output.md)，输入供数见[三通道调度](Cluster_Input_Overlap.md)。
