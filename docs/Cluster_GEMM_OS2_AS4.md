# 单 Cluster K512 OS2 AS4 GEMM

本例计算 `X[32,512]×W[512,16]`，M=32、K=512、N=16。仅使用一个Cluster：八Macro全归约，每次提供K256/N4；OS2覆盖两段K，AS4依次覆盖四组N。每行X为一个独立batch，配置W8A16、signed_en=1、os_cnt=2、as_cnt=4、ws_cnt=1。

## 权重地址与ACT布局

每Macro的每行仍为4个OC×32B=128B。整个W矩阵需要512×16×1B=8KiB，即每Macro8行、每Macro1KiB。常规WLC接口预写64次128B并读回校验，计算中不重写权重。

| 地址 | K Tile | K范围 | AS Context | N范围 |
|---|---|---|---|---|
| 0x60 | 0 | 0～255 | 0 | 0～3 |
| 0x61 | 0 | 0～255 | 1 | 4～7 |
| 0x62 | 0 | 0～255 | 2 | 8～11 |
| 0x63 | 0 | 0～255 | 3 | 12～15 |
| 0x64 | 1 | 256～511 | 0 | 0～3 |
| 0x65 | 1 | 256～511 | 1 | 4～7 |
| 0x66 | 1 | 256～511 | 2 | 8～11 |
| 0x67 | 1 | 256～511 | 3 | 12～15 |

表中每个地址同时对应八个Macro各自的一行。Macro p负责该K Tile的 `32*p…32*p+31`；OC c保存对应Context的第c列。精确打包公式为 `row[256*c+8*j+:8] = Wq[256*tile+32*p+j,4*context+c]`。

descriptor中 `reduce_split_mask=0`、`macro_en_mask=0xff`、`macro_oc_mask=0xffffffff`、`act_slot_sel=0xfac688`，即八个Macro分别读取ACT slot0…7。每个K Tile有256个ACT元素，完整占用4096-bit ACT bank；外部依次发送4个1024-bit Plane，不提前减ACT_zp。A3按signed digit解释。

## Command与发射

OS>1 AS保持Tile→Slice→Context顺序。每个K Tile接收4条地址Command；Context0 Command同时加载A0，后续Context1/2/3 Command分别与A1/A2/A3同拍。ACT只保存一份，内部逐slice在四个Context之间复用。

| 每行相对周期 | 外部Command / ACT | 内部发射 |
|---|---|---|
| C0 | Tile0/Context0，0x60，A0 | — |
| C1～C3 | Tile0/Context1～3，0x61～63，A1～A3 | Tile0/A0/Context0～2 |
| C4 | 无新输入 | Tile0/A0/Context3 |
| C5～C8 | 无新输入 | Tile0/A1/Context0～3 |
| C9～C12 | 无新输入 | Tile0/A2/Context0～3 |
| C13～C16 | 无新输入 | Tile0/A3/Context0～3 |
| C17 | Tile1/Context0，0x64，A0 | — |
| C18～C20 | Tile1/Context1～3，0x65～67，A1～A3 | Tile1/A0/Context0～2 |
| C21～C29 | 无新输入 | 按相同顺序推进 |
| C30～C33 | 无新输入 | Tile1/A3/Context0～3 |
| C35～C38 | 排空 | Context0～3的最终raw依次发布 |
| C36～C39 | 排空 | 对应INT8依次发布，比raw晚1T |

每行8条Command、32次内部发射，32行共256条Command、1024次发射。物理输出只有4个OC，AS四个Context依次形成16列；M由TB外层逐行推进，不编码为本批WS32。AS每次切换地址均刷新weight Hold，ACT在各Context间保持。

## Psum与量化参数

四个Context各使用一项Psum历史，默认深度16足够。每个phase均更新当前Context：Tile0建立融合历史，Tile1继续累加；最终完成全部K512后只量化一次。Python生成4096项历史golden，逐次与真实Psum寄存器比较。

量化按确认的单一逐通道zp接口实现，输入补偿已由参数生成端合入zp：

```text
q[m,n] = clip_INT8(round(raw[m,n] * multiplier * 2^shift) + requant_zp[n])
```

zp明确为per-channel，本例共用multiplier/shift，使用16个有效INT32 zp。Python先计算原始实数矩阵golden，校准共用输出scale与各列参考输出zero-point，再依据列权重和将输入offset项合入最终zp。全部golden使用整数和Fraction。Cluster直接处理raw，不重复输入补偿。

本组固定种子`0x3251216`生成：ACT_zp=−9243、W_zp=0、multiplier=2080、shift=−31。输出zp为：

```text
Context0: -88, -81, -72, -91
Context1: -59, -49, -73, -77
Context2: -72, -85, -74, -92
Context3: -65, -64, -55, -36
```

配置`REQUANT_CONTEXT_DEPTH=4`。首K Tile各Context Command提供4个zp，第二K Tile重复提供并校验一致。参数表保存16×INT32 zp共512bit，以及四Context×四组scale共672bit；每拍按最终raw的Context选四项。per-tensor使用batch第0项scale，per-channel使用当前Context四组scale，均按OC固定索引。默认depth=1使用batch四通道配置。

`requant_cfg_t`为298bit：conv_mode1+requant_mode1+4×INT32 multiplier+4×INT10 shift+4×INT32 zp。107-bit compute descriptor不变，所有量化计算最多4OC、一个对齐归约组。raw输出保持编码点积，直接经组合Requant在下一沿锁存INT8。

## 文件与测试

- `tb_Cluster_GEMM_OS2_AS4.sv`及`cluster_gemm_as_driver/scoreboard/regression.svh`：独立TB、地址/ACT驱动、Psum与输出检查、批次调度。
- `gemm_os2_as4_vectors.py`：原始矩阵、量化参数、8个权重行地址、256个ACT Plane、4096个Psum历史、512个raw/INT8 golden。
- `data/gemm_os2_as4/`：可审阅数据、实际512项输出矩阵及周期事件。

独立运行：

VCS 运行入口及各 case 的参数见 [vcs-rtl 使用说明](../vcs-rtl/README.md)。

仿真使用 [VCS case 入口](../vcs-rtl/README.md)，支持独立编译、数据生成、运行及结果检查。

硬件必须与本接口的Python整数golden完全一致。Python另存实数与中心化数学参考，记录参数折算和舍入差异，不将其当作RTL比较容差。组合路径未进行综合/STA签核。

## Per-channel weight版本

同一tb_Cluster_GEMM_OS2_AS4.sv通过+PER_CHANNEL_SCALE运行新增版本，矩阵尺寸、地址0x60～0x67、OS2/AS4和ACT时序不变。Python的--per-channel按每个输出列n的最大绝对值独立计算W_scale[n]，使用signed W8对称量化；ACT仍为per-tensor A16非对称，输出scale共用。由ACT_scale×W_scale[n]/output_scale得到各列multiplier/shift，输入补偿合入各列zp。

每个Context命令提供该4列的multiplier、shift和zp，参数c固定对应OC c；首K Tile加载，第二Tile必须保持一致。REQUANT_CONTEXT_DEPTH=4，16组scale共672bit，加16个zp共512bit，总1184bit。每拍只使用当前Context的4组，raw和量化输出周期不变。

per-channel版本重新生成编码W、raw和INT8 golden，独立检查512个raw、512个INT8和4096次Psum更新。data/gemm_os2_as4_per_channel/保存该数据。AS4的五个VCS case运行两个weight版本及三类负向诊断，共5个suite。权重per-channel并不改变合并zp的逐通道属性；两种weight版本的zp均为per-channel。

VCS执行 `make run CASE=gemm_as4_tensor` 或 `make run CASE=gemm_as4_channel`，自动生成相应数据并设置参数。三类负向使用 `as_context_capacity`、`as_context_zp_reload`、`as_context_scale_reload`。Python的--per-channel开关也可独立生成。
