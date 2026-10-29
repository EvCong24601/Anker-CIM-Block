# Cluster GEMM 用例总览

GEMM 验证由七个具体 TB、三套共用驱动执行，包含 13 个正向 case 和 5 个 AS 参数负向 case。每个正向 case 只使用一个 Cluster，通过 WLC 常规 128 B 接口写入并读回权重，再驱动 Command 和完整 ACT Plane。检查范围包括整数点积、物理输出 lane、raw/INT8 数值、输出周期、寄存器保持、权重 Hold 和适用的 Psum 历史。

## 公共约定

- 正向 case 统一命名为 `gemm_os{OS}_ws{WS}_as{AS}_{精度}[_{场景}]_{tensor|channel}`，三个 count 均显式标出，包括值为 1 的字段。运行时使用完整新名称；TB、文件列表、数据生成器及 TB 的 PASS 标志沿用现有名称。
- `M/K/N` 对应 `X[M,K] × W[K,N]`。启用 Requant 时，每个归约组最多输出 4 个 OC，N 方向由批次或 AS Context 覆盖。
- ACT 使用 per-tensor 非对称量化，weight 使用对称量化。WS32、AS4、高位置组和 N 尾部场景分别具有 per-tensor weight 与 per-channel weight 配置；舍入/饱和场景使用定向 per-channel 参数。
- `conv_mode`为唯一1bit模式控制：1表示weight per-channel，0表示weight per-tensor。
- 合并输入补偿后的 `zp` 始终逐通道；per-tensor仅TB保存并在CIM饱和INT8输出后相加、再次饱和，per-channel保持CIM内饱和前相加。per-tensor scale 使用当前Context的参数项 0；per-channel scale 使用 OC 对应项。参数项 c 固定对应 OC c，mask 空洞不压缩索引。
- Python 生成实数参考、整数矩阵、量化参数、权重行、ACT Plane 和整数 golden。SV 检查真实 Macro 乘法及归约路径，输出矩阵与整数 golden 精确比较。
- raw 经组合 Requant 后，在下一时钟沿写入 INT8 输出寄存器，量化 valid 比 raw 晚 1T。输出为 valid-only 接口，下游须在有效周期接收。

## 已舍入 ZP 与 TB 修正

生成端按`ZP_n=Z_y_reference[n]+R((-ACT_zp×sum(Wq[:,n]))×S_hat_n)`生成signed INT32整数补偿，两种模式均已完成该round。per-tensor的TB只做`clip_INT8(signed(CIM_INT8)+ZP_n)`，不再round；per-channel的TB直接比较RTL已完成round、加ZP及clip的INT8结果。

先分别检查CIM端口golden与最终golden，再记录原单次饱和算法差异。per-tensor两次饱和不能还原已丢失的数值；per-channel原顺序保持不变。数学展开、位宽与舍入规则见[Requant说明](Cluster_Requant.md)。

## W8A16：OS1 / WS32

`X[32,128] × W[128,16]`，`cim_os_cnt/cim_ws_cnt/cim_as_cnt=1/32/1`。八个 Macro 根归约，物理 K256 中高 K128 补零；四批 N4 对应地址 `0x40～0x43`。每批重放 32 行 ACT，OS1 旁路 Psum。

- `gemm_os1_ws32_as1_w8a16_tensor`：per-tensor weight 与共享 multiplier/shift。
- `gemm_os1_ws32_as1_w8a16_channel`：per-channel weight 与逐 OC multiplier/shift。

每项检查 512 个 raw 和 512 个 INT8。每批第 m 行在 `C(5m)` 接受 Command，raw 在 `C(5m+9)` 发布，INT8 在 `C(5m+10)` 发布。

TB 为 `tb_Cluster_GEMM_OS1_WS32_W8A16.sv`，文件列表为 `verilog_file_gemm_os1_ws32_w8a16.f`。

## W8A16：OS2 / AS4

`X[32,512] × W[512,16]`，`cim_os_cnt/cim_ws_cnt/cim_as_cnt=2/1/4`。八个 Macro 每次覆盖 K256/N4，OS2 覆盖 K512，四个 AS Context 覆盖 N16。每行 X 为独立 batch；权重地址 `0x60～0x63` 对应 Tile0，`0x64～0x67` 对应 Tile1。

- `gemm_os2_ws1_as4_w8a16_tensor`：per-tensor weight 与共享 multiplier/shift。
- `gemm_os2_ws1_as4_w8a16_channel`：per-channel weight 与逐 Context、逐 OC multiplier/shift。

每项检查 512 个 raw、512 个 INT8 和 4096 次 Psum 更新。每行相对首命令的 raw 为 C35～C38，INT8 为 C36～C39。默认 `ZP_DEPTH=16`（兼容名称，同时限制scale表），四个 Context 使用其中四项；以下ZP位数仅为per-channel有效参数，per-tensor不加载ZP：有效参数为512 bit zp和672 bit scale，共1184 bit；整表容量为4736 bit。

TB 为 `tb_Cluster_GEMM_OS2_AS4_W8A16.sv`，文件列表为 `verilog_file_gemm_os2_as4_w8a16.f`。

## W8A16：OS1 / WS1 / AS8

- `gemm_os1_ws1_as8_w8a16_tensor`
- `gemm_os1_ws1_as8_w8a16_channel`

计算 `X[8,256] × W[256,32]`，每行独立一批，无需 OS 累加；八个 AS Context 覆盖 N32，共用一份 ACT。每 Context 对应八个 Macro 的一个权重地址，地址为 `0xc0～0xc7`，共 8 KiB。C0～C7 连续接收八条 Command，A0～A3 仅在 C0～C3 输入；内部 C1～C32 按 Slice → Context 发射。首行 raw 为 C30～C37，INT8 为 C31～C38。

每项检查 256 个 raw、256 个 INT8、1024 次逐 Slice/Context 的 Psum 更新、64 条 Command 及 256 次发射。两个量化模式分别运行；per-tensor 的 ZP 仍仅在 TB 修正，per-channel 的参数逐 OC 加载。

`cluster_gemm_as_gates.svh`逐拍检查真实 table clock：A16 不开启单地址旁路时钟；计算批次内权重地址和共享 scale 表时钟开启，空闲时关闭；tensor 模式关闭额外通道 scale/ZP 时钟。当前是整批表门控，非逐项时钟门控；同时逐项检查无 accepted write 时地址、multiplier、shift 和 ZP 均保持。

命令切换在无复位的八行之间轮换逻辑列组，`logical_context=(context+row_m)%8`，地址、参数与矩阵输出列同步映射，防止旧批次内容误用。接收新 Context 时上一 Context 已开始发射；后续 `cmd_valid=0` 时翻转整个 Command、地址与量化配置，验证未接受的输入不会污染在途运算。每项强制覆盖 56 次接收/发射重叠、56 次后续行 Context 重载，并要求有效期、空闲期及保持检查均非零。

TB 为 `tb_Cluster_GEMM_OS1_WS1_AS8_W8A16.sv`，共用参数化 `ClusterGemmOs2As4.sv` 与 AS driver/scoreboard；数据由 `gemm_os1_ws1_as8_w8a16_vectors.py` 生成。运行 `make run CASE=gemm_os1_ws1_as8_w8a16_channel`，或本地 `run_sram_regression.py --gemm-as8-only --sim-dir <checkout外目录>`。

## 高位置归约组

以下 case 分别使用 `tb_Cluster_GEMM_W4A16_HighGroup.sv`、`tb_Cluster_GEMM_W2A8_HighGroup.sv` 及各自同名场景的 `.f`，共用 `ClusterGemmScenario.sv`，均计算 `X[8,192] × W[192,8]`，配置 `OS1/WS8/AS1`，分两批 N4。

- `gemm_os1_ws8_as1_w4a16_high_group_tensor`、`gemm_os1_ws8_as1_w4a16_high_group_channel`：W4A16，Macro4～7，lane4～7，地址 `0x80/0x81`；首行 raw/INT8 为 C8/C9。
- `gemm_os1_ws8_as1_w2a8_high_group_tensor`、`gemm_os1_ws8_as1_w2a8_high_group_channel`：W2A8，Macro6～7，lane12～15，地址 `0x90/0x91`；首行 raw/INT8 为 C5/C6。

每项检查 64 个 raw 和 64 个 INT8，覆盖高位置物理组的数据路由与参数映射。

## N 尾部与 OC mask 空洞

- `gemm_os1_ws8_as1_w4a16_n6_tail_tensor`
- `gemm_os1_ws8_as1_w4a16_n6_tail_channel`

计算 `X[8,160] × W[160,6]`，W4A16，`OS1/WS8/AS1`，Macro4～7，地址 `0xa0/0xa1`。第二批使用 OC0、OC2，mask 为 `0101`，逻辑列 4、5 对应 lane4、lane6。OC2 使用参数项 2；OC1/OC3 不发布 valid，INT8 寄存器保持。

每项检查 48 个 raw 和 48 个 INT8。TB 和文件列表与高位置组场景相同。

## 舍入与饱和边界

`gemm_os1_ws12_as1_w4a16_round_clip_channel` 计算 `X[12,160] × W[160,4]`，W4A16，`OS1/WS12/AS1`，Macro4～7，地址 `0xb0`。矩阵通过单位基权重形成指定点积，经过实际 Macro 及归约路径。

四项 multiplier 为 `[1,3,1,1]`、shift 为 `[-1,-2,0,0]`、合并 zp 为 `[0,1,100,-100]`。检查 48 个 raw 和 48 个 INT8，覆盖正半整数 5 项、负半整数 5 项、低端越界 2 项、高端越界 4 项，以及精确 −128/127 各 2 项。

七项合计检查 400 个 raw 和 400 个 INT8。

## AS 参数负向 case

五个 case 使用 AS4 TB，成功条件是精确命中指定诊断：

- `as_context_capacity`：`ZP_DEPTH=2` 请求 AS4，预期 `CLUSTER_REQUANT_CONFIG: AS context zp depth exceeded`。
- `as_context_capacity_default`：`ZP_DEPTH=1` 请求AS4，预期 `CLUSTER_REQUANT_CONFIG: AS context zp depth exceeded`。
- `as_context_zp_reload`：per-channel下同一 Context 跨 K Tile 改变 zp，预期 `CLUSTER_REQUANT_CONFIG: AS context zp changed across K Tiles`。
- `as_context_scale_reload`：per-channel 配置跨 K Tile 改变 scale，预期 `CLUSTER_REQUANT_CONFIG: AS context scale changed across K Tiles`。
- `as_context_tensor_scale_reload`：mode=0下同一Context跨K Tile改变第0项scale，预期 `CLUSTER_REQUANT_CONFIG: AS context scale changed across K Tiles`。

## 运行与结果

在 `vcs-rtl/` 目录执行：

```sh
make run CASE=gemm_os1_ws32_as1_w8a16_channel
make run CASE=gemm_os2_ws1_as4_w8a16_channel
make run CASE=gemm_os1_ws8_as1_w4a16_n6_tail_channel
make gemm-regression
make run CASE=as_context_capacity
make run CASE=as_context_zp_reload
make run CASE=as_context_scale_reload
```

`make gemm-regression` 执行全部 13 个正向 GEMM，合计检查 2960 个 raw 和 2960 个 INT8；`make regression` 包含这 13 项及 5 项 AS 参数负向测试。`make list` 列出完整 case 目录。

每项结果存放于 `work/<CASE>/`，包含 data、编译/运行日志和带 case 后缀的 FSDB。case 与 N 批次开始时输出英文时间戳和描述。数据生成、退出状态与诊断检查由 `cases.py` 管理；参数及波形命名见 [VCS 使用说明](../vcs-rtl/README.md)。

## 权重与 ACT 物理布局

WS32 使用地址0x40～0x43，每地址对应八个Macro的一行，共1KiB；四地址共4KiB，写入/读回各32次。Macro m、OC c的byte j保存 `Wq[32*m+j,4*N_tile+c]`，超出逻辑K128的权重为0。Macro4～7和ACT高128个K位置均补零。

AS4 使用 `address=0x60+4*tile+context`，每Macro8行、共8KiB，写入/读回各64次。打包公式为 `row[256*c+8*j+:8]=Wq[256*tile+32*macro+j,4*context+c]`。每K Tile的256个ACT元素占用完整4096-bit bank。

两个W8A16场景的descriptor均为cim_precision=6、cim_signed_en=1、cim_reduce_split_mask=0、cim_macro_en_mask=0xff、cim_macro_oc_mask=0xffffffff、cim_act_slot_sel=0xfac688。A0与首Command同拍输入，A1～A3连续输入；A3按signed digit解释。ACT输入端不减ACT_zp。

AS4每行在C0～C3接收Tile0四条地址及A0～A3，在C1～C16按Slice→Context发射；C17～C20接收Tile1输入，在C18～C33发射。每行8条Command、32次发射；全矩阵256条Command、1024次发射，最终raw在C35～C38依Context顺序发布。

W4高位置组使用split=0x01、EN=0xf0；W2高位置组使用split=0x07、EN=0xc0。所有K尾部和N无效OC对应权重补零。

## Golden 与量化参数

Python先生成实数矩阵参考，再校准ACT、weight及输出scale。整数golden使用任意精度整数与Fraction，舍入为半整数远离零；RTL必须精确匹配`cim_golden.hex`。per-tensor的TB再按channel加ZP、饱和，与`quant_golden.hex`精确比较；per-channel两份golden相同。`original_quant_reference.hex`保留原单次饱和算法供差异统计。实数或中心化数学参考用于记录量化及合并zp的舍入差异，不作为硬件容差。通用公式和参数索引见 [Requant](Cluster_Requant.md)。

WS32种子为0x3212816；per-tensor配置ACT_zp=−9264、multiplier=4649、shift=−31。AS4种子为0x3251216；per-tensor配置ACT_zp=−9243、multiplier=2080、shift=−31。两者weight_zp均为0，合并zp逐通道。

per-channel weight按每个输出列独立校准并量化W，使用该列对应的multiplier/shift及合并zp。WS32和AS4通过 `+PER_CHANNEL_SCALE` 选择该模式，必须使用匹配的数据目录。边界TB由数据配置决定模式，不需要该plusarg。

## TB 与数据文件

- `tb_Cluster_GEMM_OS1_WS32_W8A16.sv`（薄壳，主体在共用的 `ClusterGemmOs1Ws32.sv`）：`cluster_gemm_driver/scoreboard/regression.svh`负责WLC加载、WS驱动、Hold/Psum旁路、输出周期及矩阵收集；golden生成器为 `gemm_os1_ws32_w8a16_vectors.py`。
- `tb_Cluster_GEMM_OS2_AS4_W8A16.sv`（薄壳，主体在共用的 `ClusterGemmOs2As4.sv`）：`cluster_gemm_as_driver/scoreboard/regression.svh`负责地址与参数加载、ACT复用、4096次Psum历史及矩阵输出；golden生成器为 `gemm_os2_as4_w8a16_vectors.py`。
- `tb_Cluster_GEMM_W4A16_HighGroup.sv`、`tb_Cluster_GEMM_W2A8_HighGroup.sv`、`tb_Cluster_GEMM_W4A16_N6_Tail.sv`、`tb_Cluster_GEMM_W4A16_RoundClip.sv`：通过共用的 `ClusterGemmScenario.sv`，`cluster_gemm_scenario_driver/scoreboard/regression.svh`负责高位置物理组、OC空洞、mask/参数索引和舍入饱和；golden生成器为 `gemm_scenario_vectors.py`。

上述include均位于 `RTL/cluster/tb/include/`，Python位于 `RTL/cluster/tb/py/`。`data/gemm_os1_ws32_w8a16[_per_channel]/`、`data/gemm_os2_as4_w8a16[_per_channel]/`及 `data/gemm_scenarios/` 保存矩阵、参数、权重行、ACT Plane、输入计划、golden、观测CSV与SHA256。仿真使用的可写副本由VCS case入口生成。

七个具体TB与七个独立GEMM文件列表对应；四个场景TB实例化共用的`ClusterGemmScenario`，WS32 TB实例化`ClusterGemmOs1Ws32`，AS4与AS8 TB共用参数化`ClusterGemmOs2As4`，各自固定场景并校验数据尺寸/精度。Tensor/channel模式仍由匹配的数据集决定，OC映射不变。默认FSDB名称包含具体TB，VCS运行时附加完整case名称（包括tensor/channel）。

此前命名下的11个正向GEMM和5个AS参数负向用例均通过，结果与golden匹配；133个Make入口和全部文件列表路径检查通过。证据见`RTL/cluster/tb/log/concrete_gemm_names_validation.log`、`concrete_gemm_names_audit.log`和`concrete_gemm_names_sources.sha256`。历史全量回归日志保留其当时的文件名和源码哈希，不用于证明当前命名的路径有效性。

2026-10-29 本轮统一 count 命名并补充 AS8 后，ModelSim 全量135组通过（45个正向、90个预期拒绝），13个正向GEMM全部逐元素匹配。每个AS8量化模式覆盖304个表时钟开启周期、161个空闲关钟周期、7376次表项保持、56次接收/发射重叠及56次跨行重载；五项故障注入均被新增断言拒绝。135个Make入口dry-run和全部文件列表检查通过，AS4既有数据逐字节不变。结果与受测源码哈希见 `RTL/cluster/tb/log/gemm_as8_counts_validation.log`、`gemm_as8_counts_sources.sha256`。
