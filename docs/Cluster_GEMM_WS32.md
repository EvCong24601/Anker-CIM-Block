# 单 Cluster W8A16 WS32 GEMM

本例计算`X[32,128]×W[128,16]`，只实例化一个Cluster，分两批N8。两批共用X和per-tensor multiplier/shift，ACT为signed A16非对称量化、weight为signed W8对称量化。逐通道INT32 zp由参数生成端合入输入补偿，Cluster直接量化raw Psum。

## 资源和权重地址

W8下每个Macro包含4个OC，每OC保存32个INT8权重。四Macro沿K归约得到K128/N4；同一Cluster的两组Macro并行得到K128/N8。两批N8拼成N16，并非两个时钟周期完成整个矩阵。

每个Macro预先写入两行：`0x40`保存N=0～7对应的权重，`0x41`保存N=8～15。计算中只切换读地址，不重新写SRAM。用WLC常规128B端口写入并逐Macro读回校验，共16次写入和16次读回。

| Macro | K范围 | 0x40 的N范围 | 0x41 的N范围 | ACT slot |
|---|---|---|---|---|
| 0 | 0～31 | 0～3 | 8～11 | 0 |
| 1 | 32～63 | 0～3 | 8～11 | 1 |
| 2 | 64～95 | 0～3 | 8～11 | 2 |
| 3 | 96～127 | 0～3 | 8～11 | 3 |
| 4 | 0～31 | 4～7 | 12～15 | 0 |
| 5 | 32～63 | 4～7 | 12～15 | 1 |
| 6 | 64～95 | 4～7 | 12～15 | 2 |
| 7 | 96～127 | 4～7 | 12～15 | 3 |

Macro的128B行内，OC c占32B，byte j放置 `Wq[32*(macro%4)+j, 8*N_tile+4*(macro/4)+c]` 的INT8二补码。常规访问时 `cim_macro_group=macro/4`、`cim_bank_sel=macro%4`、`cim_wmask=0`。

## Command与ACT输入

两批各有32条Command，每条对应X的一行。每批的descriptor固定为：

```text
precision             = 6       // W8A16
signed_en             = 1       // signed ACT and signed weight storage
os_cnt / ws_cnt / as_cnt = 1 / 32 / 1
reduce_split_mask     = 0x01    // {Macro0..3}, {Macro4..7}
macro_en_mask         = 0xff
macro_oc_mask         = 0xffffffff
act_slot_sel          = 0x688688 // [0,1,2,3,0,1,2,3]
weight_cim_raddr      = 0x40 (N_tile0) / 0x41 (N_tile1)
```

每批首Command锁存该批8个输出列的zp，multiplier/shift两批相同。首条Command与该行ACT的A0同沿接受，随后三个连续沿输入A1/A2/A3，尾部ACT没有独立握手。第5拍发射已寄存的A3，下一行A0在再下一沿接受。每行包间隔5T；两批间先排空raw/INT8输出，再切换地址和zp并重新输入相同的32行X。

ACT第ph个Plane的 `[4*k+:4] = (Xq[m,k] >> (4*ph)) & 0xf`。仅低512 bit对应128个K元素，高512 bit清零。A3使用signed高位digit解释，A0/A1/A2为unsigned digit；不在TB中提前减去ACT_zp。

| 每批相对周期 | 外部输入 | 内部发射 | 输出 |
|---|---|---|---|
| C0 | 行0 Command + A0 | — | — |
| C1～C3 | 行0 A1～A3 | 行0 A0～A2 | — |
| C4 | 无新ACT包 | 行0 A3 | — |
| C5 | 行1 Command + A0 | — | — |
| C8 | 行1 A3 | 行1 A2 | 行0 raw，8个OC |
| C9 | 无新ACT包 | 行1 A3 | 行0 INT8，8个OC |
| C155～C158 | 行31 Command + A0～A3 | 按相同规则 | 较早行输出 |
| C159 | 无新ACT包 | 行31 A3 | — |
| C163 / C164 | 排空 | — | 最后一行raw / INT8 |

每批128次内部发射，八个Macro都只在首发射刷新weight Hold，后127次复用。第二批换到0x41时各Macro再次刷新一次。全例共64条Command、256次内部发射、512个raw和512个INT8元素。OS1全程旁路Psum，所以WS32无需将Psum深度16扩大到32。

## Python矩阵与量化golden

`gemm_vectors.py`使用固定种子`0x3212816`生成实数X和W，先计算原始实数矩阵乘积，再做校准：

1. 对整个X张量计算signed A16非对称scale和zero-point；本例 `ACT_zp=-9264`。
2. 对整个W张量计算signed W8对称scale，`W_zp=0`。
3. 用原始实数GEMM的最小/最大值校准输出signed INT8张量，得到output scale与`output_zp=4`。
4. 从 `X_scale*W_scale/output_scale` 得到共用定点缩放：`multiplier=4649`，`shift=-31`。
5. 参数生成端按列权重和，将输入offset合入`zp[n]=output_zp_reference+round((-ACT_zp*sum(Wq[:,n]))*4649/2^31)`。
6. 计算`raw=Xq*Wq`，生成`q=clip(round(raw*4649/2^31)+zp[n])`，作为必须逐位一致的INT8 golden。

两批的输出zp分别为：

```text
N 0..7 : -65, -37, -48, -9, -13, 14, 24, 4
N 8..15:  16,  53,   8, 39,  45, 53, 36, 48
```

所有量化与舍入的Python计算使用任意精度整数/Fraction，不依赖浮点舍入或SV实现函数。原始实数矩阵CSV用于审阅和校准。

本例严格按raw缩放舍入后加有效INT32 zp的接口生成golden。Python另存中心化数学参考，记录融合偏置时的定点舍入差异；本组与原始实数GEMM量化参考最大差异1，硬件与接口整数golden必须完全一致。

## 文件与复现

- `tb_Cluster_GEMM_OS1_WS32.sv`：一个真实Cluster实例、矩阵存储与共享验证状态。
- `include/cluster_gemm_driver.svh`：加载Python文件、独立SV矩阵点积复核、权重/ACT打包检查、SRAM预加载、两批Command/ACT驱动。
- `include/cluster_gemm_scoreboard.svh`：按lane输出次序重建M/N，逐元素检查raw和INT8、逐拍检查地址/ACT/phase、权重刷新次数、Psum旁路、INT8延迟及寄存器保持。
- `include/cluster_gemm_regression.svh`：两批N调度、排空、覆盖检查及完整观测矩阵输出。
- `data/gemm_ws32/`：实数/整数矩阵、512个输出golden、量化参数、物理权重行、ACT Plane、输入计划、实际输出矩阵和周期记录。

从仓库根目录运行独立测试：

```text
python RTL/cluster/tb/py/run_sram_regression.py --gemm-only
```

`--full`也包含此case，并重跑全部原有计算、SRAM、容量和Requant测试。脚本在仓库外建立独立副本、记录RTL/TB源码SHA256；仿真结束后Python再次逐元素比对SV输出矩阵。

也可只重新生成激励：

```text
python RTL/cluster/tb/py/gemm_vectors.py /absolute/path/gemm_data
```

VCS入口选择`TB=gemm`，先`make gemm-vectors`，再`make com TB=gemm`；仿真传入`PVALUE=+GEMM_DATA_DIR=/absolute/path/vcs-rtl/work/gemm_data`。`make check TB=gemm`检查成功标志。VCS源文件路径已同步；本机验证使用ModelSim。
