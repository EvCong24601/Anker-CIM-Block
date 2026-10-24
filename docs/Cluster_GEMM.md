# Cluster GEMM 用例总览

GEMM 验证由三个 TB 执行，包含 11 个正向 case 和 3 个 AS 参数负向 case。每个正向 case 只使用一个 Cluster，通过 WLC 常规 128 B 接口写入并读回权重，再驱动 Command 和完整 ACT Plane。检查范围包括整数点积、物理输出 lane、raw/INT8 数值、输出周期、寄存器保持、权重 Hold 和适用的 Psum 历史。

## 公共约定

- `M/K/N` 对应 `X[M,K] × W[K,N]`。启用 Requant 时，每个归约组最多输出 4 个 OC，N 方向由批次或 AS Context 覆盖。
- ACT 使用 per-tensor 非对称量化，weight 使用对称量化。WS32、AS4、高位置组和 N 尾部场景分别具有 per-tensor weight 与 per-channel weight 配置；舍入/饱和场景使用定向 per-channel 参数。
- 合并输入补偿后的 `zp` 始终逐通道。per-tensor scale 使用参数项 0；per-channel scale 使用 OC 对应项。参数项 c 固定对应 OC c，mask 空洞不压缩索引。
- Python 生成实数参考、整数矩阵、量化参数、权重行、ACT Plane 和整数 golden。SV 检查真实 Macro 乘法及归约路径，输出矩阵与整数 golden 精确比较。
- raw 经组合 Requant 后，在下一时钟沿写入 INT8 输出寄存器，量化 valid 比 raw 晚 1T。输出为 valid-only 接口，下游须在有效周期接收。

## W8A16：OS1 / WS32

`X[32,128] × W[128,16]`，`os_cnt/ws_cnt/as_cnt=1/32/1`。八个 Macro 根归约，物理 K256 中高 K128 补零；四批 N4 对应地址 `0x40～0x43`。每批重放 32 行 ACT，OS1 旁路 Psum。

- `gemm_ws32_tensor`：per-tensor weight 与共享 multiplier/shift。
- `gemm_ws32_channel`：per-channel weight 与逐 OC multiplier/shift。

每项检查 512 个 raw 和 512 个 INT8。每批第 m 行在 `C(5m)` 接受 Command，raw 在 `C(5m+9)` 发布，INT8 在 `C(5m+10)` 发布。

TB 为 `tb_Cluster_GEMM_OS1_WS32.sv`，文件列表为 `verilog_file_gemm_ws32.f`。

## W8A16：OS2 / AS4

`X[32,512] × W[512,16]`，`os_cnt/ws_cnt/as_cnt=2/1/4`。八个 Macro 每次覆盖 K256/N4，OS2 覆盖 K512，四个 AS Context 覆盖 N16。每行 X 为独立 batch；权重地址 `0x60～0x63` 对应 Tile0，`0x64～0x67` 对应 Tile1。

- `gemm_as4_tensor`：per-tensor weight 与共享 multiplier/shift。
- `gemm_as4_channel`：per-channel weight 与逐 Context、逐 OC multiplier/shift。

每项检查 512 个 raw、512 个 INT8 和 4096 次 Psum 更新。每行相对首命令的 raw 为 C35～C38，INT8 为 C36～C39。四个 Context 的参数表使用 512 bit zp 和 672 bit scale，共 1184 bit，`ZP_DEPTH=4`。

TB 为 `tb_Cluster_GEMM_OS2_AS4.sv`，文件列表为 `verilog_file_gemm_as4.f`。

## 高位置归约组

以下 case 使用 `tb_Cluster_GEMM_Edges.sv` 和 `verilog_file_gemm_edges.f`，均计算 `X[8,192] × W[192,8]`，配置 `OS1/WS8/AS1`，分两批 N4。

- `gemm_edge_w4_high_tensor`、`gemm_edge_w4_high_channel`：W4A16，Macro4～7，lane4～7，地址 `0x80/0x81`；首行 raw/INT8 为 C8/C9。
- `gemm_edge_w2_high_tensor`、`gemm_edge_w2_high_channel`：W2A8，Macro6～7，lane12～15，地址 `0x90/0x91`；首行 raw/INT8 为 C5/C6。

每项检查 64 个 raw 和 64 个 INT8，覆盖高位置物理组的数据路由与参数映射。

## N 尾部与 OC mask 空洞

- `gemm_edge_n_tail_tensor`
- `gemm_edge_n_tail_channel`

计算 `X[8,160] × W[160,6]`，W4A16，`OS1/WS8/AS1`，Macro4～7，地址 `0xa0/0xa1`。第二批使用 OC0、OC2，mask 为 `0101`，逻辑列 4、5 对应 lane4、lane6。OC2 使用参数项 2；OC1/OC3 不发布 valid，INT8 寄存器保持。

每项检查 48 个 raw 和 48 个 INT8。TB 和文件列表与高位置组场景相同。

## 舍入与饱和边界

`gemm_edge_boundaries_channel` 计算 `X[12,160] × W[160,4]`，W4A16，`OS1/WS12/AS1`，Macro4～7，地址 `0xb0`。矩阵通过单位基权重形成指定点积，经过实际 Macro 及归约路径。

四项 multiplier 为 `[1,3,1,1]`、shift 为 `[-1,-2,0,0]`、合并 zp 为 `[0,1,100,-100]`。检查 48 个 raw 和 48 个 INT8，覆盖正半整数 5 项、负半整数 5 项、低端越界 2 项、高端越界 4 项，以及精确 −128/127 各 2 项。

七项合计检查 400 个 raw 和 400 个 INT8。

## AS 参数负向 case

三个 case 使用 AS4 TB，成功条件是精确命中指定诊断：

- `as_context_capacity`：`ZP_DEPTH=2` 请求 AS4，预期 `CLUSTER_REQUANT_CONFIG: AS context zp depth exceeded`。
- `as_context_zp_reload`：同一 Context 跨 K Tile 改变 zp，预期 `CLUSTER_REQUANT_CONFIG: AS context zp changed across K Tiles`。
- `as_context_scale_reload`：per-channel 配置跨 K Tile 改变 scale，预期 `CLUSTER_REQUANT_CONFIG: AS context scale changed across K Tiles`。

## 运行与结果

在 `vcs-rtl/` 目录执行：

```sh
make run CASE=gemm_ws32_channel
make run CASE=gemm_as4_channel
make run CASE=gemm_edge_n_tail_channel
make gemm-regression
make run CASE=as_context_capacity
make run CASE=as_context_zp_reload
make run CASE=as_context_scale_reload
```

`make gemm-regression` 执行全部 11 个正向 GEMM，合计检查 2448 个 raw 和 2448 个 INT8；`make regression` 包含这 11 项及 3 项 AS 参数负向测试。`make list` 列出完整 case 目录。

每项结果存放于 `work/<CASE>/`，包含 data、编译/运行日志和带 case 后缀的 FSDB。case 与 N 批次开始时输出英文时间戳和描述。数据生成、退出状态与诊断检查由 `cases.py` 管理；参数及波形命名见 [VCS 使用说明](../vcs-rtl/README.md)。

## 权重与 ACT 物理布局

WS32 使用地址0x40～0x43，每地址对应八个Macro的一行，共1KiB；四地址共4KiB，写入/读回各32次。Macro m、OC c的byte j保存 `Wq[32*m+j,4*N_tile+c]`，超出逻辑K128的权重为0。Macro4～7和ACT高128个K位置均补零。

AS4 使用 `address=0x60+4*tile+context`，每Macro8行、共8KiB，写入/读回各64次。打包公式为 `row[256*c+8*j+:8]=Wq[256*tile+32*macro+j,4*context+c]`。每K Tile的256个ACT元素占用完整4096-bit bank。

两个W8A16场景的descriptor均为precision=6、signed_en=1、reduce_split_mask=0、macro_en_mask=0xff、macro_oc_mask=0xffffffff、act_slot_sel=0xfac688。A0与首Command同拍输入，A1～A3连续输入；A3按signed digit解释。ACT输入端不减ACT_zp。

AS4每行在C0～C3接收Tile0四条地址及A0～A3，在C1～C16按Slice→Context发射；C17～C20接收Tile1输入，在C18～C33发射。每行8条Command、32次发射；全矩阵256条Command、1024次发射，最终raw在C35～C38依Context顺序发布。

W4高位置组使用split=0x01、EN=0xf0；W2高位置组使用split=0x07、EN=0xc0。所有K尾部和N无效OC对应权重补零。

## Golden 与量化参数

Python先生成实数矩阵参考，再校准ACT、weight及输出scale。整数golden使用任意精度整数与Fraction，舍入为半整数远离零；RTL必须精确匹配接口golden。实数或中心化数学参考用于记录量化及合并zp的舍入差异，不作为硬件容差。通用公式和参数索引见 [Requant](Cluster_Requant.md)。

WS32种子为0x3212816；per-tensor配置ACT_zp=−9264、multiplier=4649、shift=−31。AS4种子为0x3251216；per-tensor配置ACT_zp=−9243、multiplier=2080、shift=−31。两者weight_zp均为0，合并zp逐通道。

per-channel weight按每个输出列独立校准并量化W，使用该列对应的multiplier/shift及合并zp。WS32和AS4通过 `+PER_CHANNEL_SCALE` 选择该模式，必须使用匹配的数据目录。边界TB由数据配置决定模式，不需要该plusarg。

## TB 与数据文件

- `tb_Cluster_GEMM_OS1_WS32.sv`：`cluster_gemm_driver/scoreboard/regression.svh`负责WLC加载、WS驱动、Hold/Psum旁路、输出周期及矩阵收集；golden生成器为 `gemm_vectors.py`。
- `tb_Cluster_GEMM_OS2_AS4.sv`：`cluster_gemm_as_driver/scoreboard/regression.svh`负责地址与参数加载、ACT复用、4096次Psum历史及矩阵输出；golden生成器为 `gemm_os2_as4_vectors.py`。
- `tb_Cluster_GEMM_Edges.sv`：`cluster_gemm_edges_driver/scoreboard/regression.svh`负责高位置物理组、OC空洞、mask/参数索引和舍入饱和；golden生成器为 `gemm_edges_vectors.py`。

上述include均位于 `RTL/cluster/tb/include/`，Python位于 `RTL/cluster/tb/py/`。`data/gemm_ws32[_per_channel]/`、`data/gemm_os2_as4[_per_channel]/`及 `data/gemm_edges/` 保存矩阵、参数、权重行、ACT Plane、输入计划、golden、观测CSV与SHA256。仿真使用的可写副本由VCS case入口生成。
