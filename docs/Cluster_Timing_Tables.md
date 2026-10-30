# Cluster 标准逐拍表

[返回项目入口](../README.md) · [调度与容量说明](Cluster_Input_Overlap.md)

## 附录 A 标准逐拍表

以下42组为raw调度/算术表，C0为首Command+A0接受沿；标准W2/W4/W8从内部发射到raw的D=3/4/5T。各表中的split/EN用于raw归约测试，不代表全部符合Requant单组限制。合法量化配置的输出比对应raw晚1T。

### A1 单 Context os=1 ws=1 as=1
每 Tile K=128；每 Context 总 K=128。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C4 | tmp捕获: R_slice → tmp；输出 |

Ctx0：末内部发射 C1，raw 完成 C4。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C4 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C5 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |

Ctx0：末内部发射 C2，raw 完成 C5。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp；输出 |

Ctx0：末内部发射 C1，raw 完成 C5。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C6 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |

Ctx0：末内部发射 C2，raw 完成 C6。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C6 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C3 | 8'h20（不变） | 读 A2(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C4 | 8'h20（不变） | 读 A3(T0,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 12) → tmp；输出 |

Ctx0：末内部发射 C4，raw 完成 C8。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C6 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |

Ctx0：末内部发射 C2，raw 完成 C7。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C6 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C3 | 8'h20（不变） | 读 A2(T0,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C4 | 8'h20（不变） | 读 A3(T0,Ctx0) | C9 | tmp捕获前 fusion: tmp + (R_slice << 12) → tmp；输出 |

Ctx0：末内部发射 C4，raw 完成 C9。

### A2 AS os=1 ws=1 as=2
每 Tile K=128；每 Context 总 K=128。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | — |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C4 | 填充: R_slice → P[0]；输出 |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C5 | 填充: R_slice → P[1]；输出 |

Ctx0：末内部发射 C1，raw 完成 C4；Ctx1：末内部发射 C2，raw 完成 C5。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C4 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C5 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C6 | fusion: P[0] + (R_slice << 4) → P[0]；输出 |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C7 | fusion: P[1] + (R_slice << 4) → P[1]；输出 |

Ctx0：末内部发射 C3，raw 完成 C6；Ctx1：末内部发射 C4，raw 完成 C7。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | — |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C5 | 填充: R_slice → P[0]；输出 |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C6 | 填充: R_slice → P[1]；输出 |

Ctx0：末内部发射 C1，raw 完成 C5；Ctx1：末内部发射 C2，raw 完成 C6。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C5 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C6 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C7 | fusion: P[0] + (R_slice << 4) → P[0]；输出 |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C8 | fusion: P[1] + (R_slice << 4) → P[1]；输出 |

Ctx0：末内部发射 C3，raw 完成 C7；Ctx1：末内部发射 C4，raw 完成 C8。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C5 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C6 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C7 | fusion: P[0] + (R_slice << 4) → P[0] |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C8 | fusion: P[1] + (R_slice << 4) → P[1] |
| C5 | 8'h20 | 读 A2(T0)，Ctx0复用 | C9 | fusion: P[0] + (R_slice << 8) → P[0] |
| C6 | 8'h21 | 读 A2(T0)，Ctx1复用 | C10 | fusion: P[1] + (R_slice << 8) → P[1] |
| C7 | 8'h20 | 读 A3(T0)，Ctx0复用 | C11 | fusion: P[0] + (R_slice << 12) → P[0]；输出 |
| C8 | 8'h21 | 读 A3(T0)，Ctx1复用 | C12 | fusion: P[1] + (R_slice << 12) → P[1]；输出 |

Ctx0：末内部发射 C7，raw 完成 C11；Ctx1：末内部发射 C8，raw 完成 C12。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C6 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C7 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C8 | fusion: P[0] + (R_slice << 4) → P[0]；输出 |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C9 | fusion: P[1] + (R_slice << 4) → P[1]；输出 |

Ctx0：末内部发射 C3，raw 完成 C8；Ctx1：末内部发射 C4，raw 完成 C9。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C6 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C7 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C8 | fusion: P[0] + (R_slice << 4) → P[0] |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C9 | fusion: P[1] + (R_slice << 4) → P[1] |
| C5 | 8'h20 | 读 A2(T0)，Ctx0复用 | C10 | fusion: P[0] + (R_slice << 8) → P[0] |
| C6 | 8'h21 | 读 A2(T0)，Ctx1复用 | C11 | fusion: P[1] + (R_slice << 8) → P[1] |
| C7 | 8'h20 | 读 A3(T0)，Ctx0复用 | C12 | fusion: P[0] + (R_slice << 12) → P[0]；输出 |
| C8 | 8'h21 | 读 A3(T0)，Ctx1复用 | C13 | fusion: P[1] + (R_slice << 12) → P[1]；输出 |

Ctx0：末内部发射 C7，raw 完成 C12；Ctx1：末内部发射 C8，raw 完成 C13。

### A3 WS os=1 ws=2 as=1
每 Tile K=128；每 Context 总 K=128。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C2 | Ctx1，wgt_raddr=8'h20 | A0(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C4 | tmp捕获: R_slice → tmp；输出 |
| C3 | 8'h20（不变） | 读 A0(T0,Ctx1) | C6 | tmp捕获: R_slice → tmp；输出 |

Ctx0：末内部发射 C1，raw 完成 C4；Ctx1：末内部发射 C3，raw 完成 C6。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C4 | — | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C4 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C5 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |
| C4 | 8'h20（不变） | 读 A0(T0,Ctx1) | C7 | tmp捕获: R_slice → tmp |
| C5 | 8'h20（不变） | 读 A1(T0,Ctx1) | C8 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |

Ctx0：末内部发射 C2，raw 完成 C5；Ctx1：末内部发射 C5，raw 完成 C8。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C2 | Ctx1，wgt_raddr=8'h20 | A0(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp；输出 |
| C3 | 8'h20（不变） | 读 A0(T0,Ctx1) | C7 | tmp捕获: R_slice → tmp；输出 |

Ctx0：末内部发射 C1，raw 完成 C5；Ctx1：末内部发射 C3，raw 完成 C7。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C4 | — | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C6 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |
| C4 | 8'h20（不变） | 读 A0(T0,Ctx1) | C8 | tmp捕获: R_slice → tmp |
| C5 | 8'h20（不变） | 读 A1(T0,Ctx1) | C9 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |

Ctx0：末内部发射 C2，raw 完成 C6；Ctx1：末内部发射 C5，raw 完成 C9。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |
| C5 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C6 | — | A1(T0) |
| C7 | — | A2(T0) |
| C8 | — | A3(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C6 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C3 | 8'h20（不变） | 读 A2(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C4 | 8'h20（不变） | 读 A3(T0,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 12) → tmp；输出 |
| C6 | 8'h20（不变） | 读 A0(T0,Ctx1) | C10 | tmp捕获: R_slice → tmp |
| C7 | 8'h20（不变） | 读 A1(T0,Ctx1) | C11 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C8 | 8'h20（不变） | 读 A2(T0,Ctx1) | C12 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C9 | 8'h20（不变） | 读 A3(T0,Ctx1) | C13 | tmp捕获前 fusion: tmp + (R_slice << 12) → tmp；输出 |

Ctx0：末内部发射 C4，raw 完成 C8；Ctx1：末内部发射 C9，raw 完成 C13。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C4 | — | A1(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C6 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |
| C4 | 8'h20（不变） | 读 A0(T0,Ctx1) | C9 | tmp捕获: R_slice → tmp |
| C5 | 8'h20（不变） | 读 A1(T0,Ctx1) | C10 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp；输出 |

Ctx0：末内部发射 C2，raw 完成 C7；Ctx1：末内部发射 C5，raw 完成 C10。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |
| C5 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C6 | — | A1(T0) |
| C7 | — | A2(T0) |
| C8 | — | A3(T0) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C6 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C3 | 8'h20（不变） | 读 A2(T0,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C4 | 8'h20（不变） | 读 A3(T0,Ctx0) | C9 | tmp捕获前 fusion: tmp + (R_slice << 12) → tmp；输出 |
| C6 | 8'h20（不变） | 读 A0(T0,Ctx1) | C11 | tmp捕获: R_slice → tmp |
| C7 | 8'h20（不变） | 读 A1(T0,Ctx1) | C12 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C8 | 8'h20（不变） | 读 A2(T0,Ctx1) | C13 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C9 | 8'h20（不变） | 读 A3(T0,Ctx1) | C14 | tmp捕获前 fusion: tmp + (R_slice << 12) → tmp；输出 |

Ctx0：末内部发射 C4，raw 完成 C9；Ctx1：末内部发射 C9，raw 完成 C14。

### A4 单 Context os=2 ws=1 as=1
每 Tile K=128；每 Context 总 K=256。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C2 | Ctx0，wgt_raddr=8'h30 | A0(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C4 | tmp捕获: R_slice；下一拍 tmp 填充 Psum → tmp；P[0] |
| C3 | 8'h30 | 读 A0(T1,Ctx0) | C6 | tmp捕获: R_slice；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |

Ctx0：末内部发射 C3，raw 完成 C6。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C4 | — | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C4 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C5 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C4 | 8'h30 | 读 A0(T1,Ctx0) | C7 | tmp捕获: R_slice → tmp |
| C5 | 8'h30（不变） | 读 A1(T1,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |

Ctx0：末内部发射 C5，raw 完成 C8。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C2 | Ctx0，wgt_raddr=8'h30 | A0(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice；下一拍 tmp 填充 Psum → tmp；P[0] |
| C3 | 8'h30 | 读 A0(T1,Ctx0) | C7 | tmp捕获: R_slice；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |

Ctx0：末内部发射 C3，raw 完成 C7。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C4 | — | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C6 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C4 | 8'h30 | 读 A0(T1,Ctx0) | C8 | tmp捕获: R_slice → tmp |
| C5 | 8'h30（不变） | 读 A1(T1,Ctx0) | C9 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |

Ctx0：末内部发射 C5，raw 完成 C9。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |
| C5 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C6 | — | A1(T1) |
| C7 | — | A2(T1) |
| C8 | — | A3(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C6 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C3 | 8'h20（不变） | 读 A2(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C4 | 8'h20（不变） | 读 A3(T0,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C6 | 8'h30 | 读 A0(T1,Ctx0) | C10 | tmp捕获: R_slice → tmp |
| C7 | 8'h30（不变） | 读 A1(T1,Ctx0) | C11 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C8 | 8'h30（不变） | 读 A2(T1,Ctx0) | C12 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C9 | 8'h30（不变） | 读 A3(T1,Ctx0) | C13 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |

Ctx0：末内部发射 C9，raw 完成 C13。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C4 | — | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C6 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C4 | 8'h30 | 读 A0(T1,Ctx0) | C9 | tmp捕获: R_slice → tmp |
| C5 | 8'h30（不变） | 读 A1(T1,Ctx0) | C10 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |

Ctx0：末内部发射 C5，raw 完成 C10。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |
| C5 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C6 | — | A1(T1) |
| C7 | — | A2(T1) |
| C8 | — | A3(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C6 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C3 | 8'h20（不变） | 读 A2(T0,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C4 | 8'h20（不变） | 读 A3(T0,Ctx0) | C9 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C6 | 8'h30 | 读 A0(T1,Ctx0) | C11 | tmp捕获: R_slice → tmp |
| C7 | 8'h30（不变） | 读 A1(T1,Ctx0) | C12 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C8 | 8'h30（不变） | 读 A2(T1,Ctx0) | C13 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C9 | 8'h30（不变） | 读 A3(T1,Ctx0) | C14 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |

Ctx0：末内部发射 C9，raw 完成 C14。

### A5 WS os=2 ws=2 as=1
每 Tile K=128；每 Context 总 K=256。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C2 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C4 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C6 | Ctx1，wgt_raddr=8'h30 | A0(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C4 | tmp捕获: R_slice；下一拍 tmp 填充 Psum → tmp；P[0] |
| C3 | 8'h20（不变） | 读 A0(T0,Ctx1) | C6 | tmp捕获: R_slice；下一拍 tmp 填充 Psum → tmp；P[1] |
| C5 | 8'h30 | 读 A0(T1,Ctx0) | C8 | tmp捕获: R_slice；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |
| C7 | 8'h30（不变） | 读 A0(T1,Ctx1) | C10 | tmp捕获: R_slice；下一拍 acc: P[1] + tmp → tmp；P[1]；输出 |

Ctx0：末内部发射 C5，raw 完成 C8；Ctx1：末内部发射 C7，raw 完成 C10。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C4 | — | A1(T0) |
| C6 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C7 | — | A1(T1) |
| C9 | Ctx1，wgt_raddr=8'h30 | A0(T1) |
| C10 | — | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C4 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C5 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C4 | 8'h20（不变） | 读 A0(T0,Ctx1) | C7 | tmp捕获: R_slice → tmp |
| C5 | 8'h20（不变） | 读 A1(T0,Ctx1) | C8 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[1] |
| C7 | 8'h30 | 读 A0(T1,Ctx0) | C10 | tmp捕获: R_slice → tmp |
| C8 | 8'h30（不变） | 读 A1(T1,Ctx0) | C11 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |
| C10 | 8'h30（不变） | 读 A0(T1,Ctx1) | C13 | tmp捕获: R_slice → tmp |
| C11 | 8'h30（不变） | 读 A1(T1,Ctx1) | C14 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[1] + tmp → tmp；P[1]；输出 |

Ctx0：末内部发射 C8，raw 完成 C11；Ctx1：末内部发射 C11，raw 完成 C14。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C2 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C4 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C6 | Ctx1，wgt_raddr=8'h30 | A0(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice；下一拍 tmp 填充 Psum → tmp；P[0] |
| C3 | 8'h20（不变） | 读 A0(T0,Ctx1) | C7 | tmp捕获: R_slice；下一拍 tmp 填充 Psum → tmp；P[1] |
| C5 | 8'h30 | 读 A0(T1,Ctx0) | C9 | tmp捕获: R_slice；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |
| C7 | 8'h30（不变） | 读 A0(T1,Ctx1) | C11 | tmp捕获: R_slice；下一拍 acc: P[1] + tmp → tmp；P[1]；输出 |

Ctx0：末内部发射 C5，raw 完成 C9；Ctx1：末内部发射 C7，raw 完成 C11。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C4 | — | A1(T0) |
| C6 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C7 | — | A1(T1) |
| C9 | Ctx1，wgt_raddr=8'h30 | A0(T1) |
| C10 | — | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C6 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C4 | 8'h20（不变） | 读 A0(T0,Ctx1) | C8 | tmp捕获: R_slice → tmp |
| C5 | 8'h20（不变） | 读 A1(T0,Ctx1) | C9 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[1] |
| C7 | 8'h30 | 读 A0(T1,Ctx0) | C11 | tmp捕获: R_slice → tmp |
| C8 | 8'h30（不变） | 读 A1(T1,Ctx0) | C12 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |
| C10 | 8'h30（不变） | 读 A0(T1,Ctx1) | C14 | tmp捕获: R_slice → tmp |
| C11 | 8'h30（不变） | 读 A1(T1,Ctx1) | C15 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[1] + tmp → tmp；P[1]；输出 |

Ctx0：末内部发射 C8，raw 完成 C12；Ctx1：末内部发射 C11，raw 完成 C15。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |
| C5 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C6 | — | A1(T0) |
| C7 | — | A2(T0) |
| C8 | — | A3(T0) |
| C10 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C11 | — | A1(T1) |
| C12 | — | A2(T1) |
| C13 | — | A3(T1) |
| C15 | Ctx1，wgt_raddr=8'h30 | A0(T1) |
| C16 | — | A1(T1) |
| C17 | — | A2(T1) |
| C18 | — | A3(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C5 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C6 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C3 | 8'h20（不变） | 读 A2(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C4 | 8'h20（不变） | 读 A3(T0,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C6 | 8'h20（不变） | 读 A0(T0,Ctx1) | C10 | tmp捕获: R_slice → tmp |
| C7 | 8'h20（不变） | 读 A1(T0,Ctx1) | C11 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C8 | 8'h20（不变） | 读 A2(T0,Ctx1) | C12 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C9 | 8'h20（不变） | 读 A3(T0,Ctx1) | C13 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 tmp 填充 Psum → tmp；P[1] |
| C11 | 8'h30 | 读 A0(T1,Ctx0) | C15 | tmp捕获: R_slice → tmp |
| C12 | 8'h30（不变） | 读 A1(T1,Ctx0) | C16 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C13 | 8'h30（不变） | 读 A2(T1,Ctx0) | C17 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C14 | 8'h30（不变） | 读 A3(T1,Ctx0) | C18 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |
| C16 | 8'h30（不变） | 读 A0(T1,Ctx1) | C20 | tmp捕获: R_slice → tmp |
| C17 | 8'h30（不变） | 读 A1(T1,Ctx1) | C21 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C18 | 8'h30（不变） | 读 A2(T1,Ctx1) | C22 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C19 | 8'h30（不变） | 读 A3(T1,Ctx1) | C23 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 acc: P[1] + tmp → tmp；P[1]；输出 |

Ctx0：末内部发射 C14，raw 完成 C18；Ctx1：末内部发射 C19，raw 完成 C23。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C3 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C4 | — | A1(T0) |
| C6 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C7 | — | A1(T1) |
| C9 | Ctx1，wgt_raddr=8'h30 | A0(T1) |
| C10 | — | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C6 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C4 | 8'h20（不变） | 读 A0(T0,Ctx1) | C9 | tmp捕获: R_slice → tmp |
| C5 | 8'h20（不变） | 读 A1(T0,Ctx1) | C10 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 tmp 填充 Psum → tmp；P[1] |
| C7 | 8'h30 | 读 A0(T1,Ctx0) | C12 | tmp捕获: R_slice → tmp |
| C8 | 8'h30（不变） | 读 A1(T1,Ctx0) | C13 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |
| C10 | 8'h30（不变） | 读 A0(T1,Ctx1) | C15 | tmp捕获: R_slice → tmp |
| C11 | 8'h30（不变） | 读 A1(T1,Ctx1) | C16 | tmp捕获前 fusion: tmp + (R_slice << 4)；下一拍 acc: P[1] + tmp → tmp；P[1]；输出 |

Ctx0：末内部发射 C8，raw 完成 C13；Ctx1：末内部发射 C11，raw 完成 C16。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | — | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |
| C5 | Ctx1，wgt_raddr=8'h20 | A0(T0) |
| C6 | — | A1(T0) |
| C7 | — | A2(T0) |
| C8 | — | A3(T0) |
| C10 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C11 | — | A1(T1) |
| C12 | — | A2(T1) |
| C13 | — | A3(T1) |
| C15 | Ctx1，wgt_raddr=8'h30 | A0(T1) |
| C16 | — | A1(T1) |
| C17 | — | A2(T1) |
| C18 | — | A3(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0,Ctx0) | C6 | tmp捕获: R_slice → tmp |
| C2 | 8'h20（不变） | 读 A1(T0,Ctx0) | C7 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C3 | 8'h20（不变） | 读 A2(T0,Ctx0) | C8 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C4 | 8'h20（不变） | 读 A3(T0,Ctx0) | C9 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 tmp 填充 Psum → tmp；P[0] |
| C6 | 8'h20（不变） | 读 A0(T0,Ctx1) | C11 | tmp捕获: R_slice → tmp |
| C7 | 8'h20（不变） | 读 A1(T0,Ctx1) | C12 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C8 | 8'h20（不变） | 读 A2(T0,Ctx1) | C13 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C9 | 8'h20（不变） | 读 A3(T0,Ctx1) | C14 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 tmp 填充 Psum → tmp；P[1] |
| C11 | 8'h30 | 读 A0(T1,Ctx0) | C16 | tmp捕获: R_slice → tmp |
| C12 | 8'h30（不变） | 读 A1(T1,Ctx0) | C17 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C13 | 8'h30（不变） | 读 A2(T1,Ctx0) | C18 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C14 | 8'h30（不变） | 读 A3(T1,Ctx0) | C19 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 acc: P[0] + tmp → tmp；P[0]；输出 |
| C16 | 8'h30（不变） | 读 A0(T1,Ctx1) | C21 | tmp捕获: R_slice → tmp |
| C17 | 8'h30（不变） | 读 A1(T1,Ctx1) | C22 | tmp捕获前 fusion: tmp + (R_slice << 4) → tmp |
| C18 | 8'h30（不变） | 读 A2(T1,Ctx1) | C23 | tmp捕获前 fusion: tmp + (R_slice << 8) → tmp |
| C19 | 8'h30（不变） | 读 A3(T1,Ctx1) | C24 | tmp捕获前 fusion: tmp + (R_slice << 12)；下一拍 acc: P[1] + tmp → tmp；P[1]；输出 |

Ctx0：末内部发射 C14，raw 完成 C19；Ctx1：末内部发射 C19，raw 完成 C24。

### A6 AS os=2 ws=1 as=2
每 Tile K=128；每 Context 总 K=256。

#### precision=0 W2A4
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | — |
| C3 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C4 | Ctx1，wgt_raddr=8'h31 | — |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C4 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C5 | 填充: R_slice → P[1] |
| C4 | 8'h30 | 读 A0(T1)，Ctx0复用 | C7 | acc: P[0] + R_slice → P[0]；输出 |
| C5 | 8'h31 | 读 A0(T1)，Ctx1复用 | C8 | acc: P[1] + R_slice → P[1]；输出 |

Ctx0：末内部发射 C4，raw 完成 C7；Ctx1：末内部发射 C5，raw 完成 C8。

#### precision=1 W2A8
split_mask=7'h07，EN=8'h55，OC_MASK=32'hFFFF_FFFF；D=3T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |
| C5 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C6 | Ctx1，wgt_raddr=8'h31 | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C4 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C5 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C6 | fusion: P[0] + (R_slice << 4) → P[0] |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C7 | fusion: P[1] + (R_slice << 4) → P[1] |
| C6 | 8'h30 | 读 A0(T1)，Ctx0复用 | C9 | acc: P[0] + R_slice → P[0] |
| C7 | 8'h31 | 读 A0(T1)，Ctx1复用 | C10 | acc: P[1] + R_slice → P[1] |
| C8 | 8'h30 | 读 A1(T1)，Ctx0复用 | C11 | fusion: P[0] + (R_slice << 4) → P[0]；输出 |
| C9 | 8'h31 | 读 A1(T1)，Ctx1复用 | C12 | fusion: P[1] + (R_slice << 4) → P[1]；输出 |

Ctx0：末内部发射 C8，raw 完成 C11；Ctx1：末内部发射 C9，raw 完成 C12。

#### precision=2 W4A4
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | — |
| C3 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C4 | Ctx1，wgt_raddr=8'h31 | — |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C5 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C6 | 填充: R_slice → P[1] |
| C4 | 8'h30 | 读 A0(T1)，Ctx0复用 | C8 | acc: P[0] + R_slice → P[0]；输出 |
| C5 | 8'h31 | 读 A0(T1)，Ctx1复用 | C9 | acc: P[1] + R_slice → P[1]；输出 |

Ctx0：末内部发射 C4，raw 完成 C8；Ctx1：末内部发射 C5，raw 完成 C9。

#### precision=3 W4A8
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |
| C5 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C6 | Ctx1，wgt_raddr=8'h31 | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C5 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C6 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C7 | fusion: P[0] + (R_slice << 4) → P[0] |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C8 | fusion: P[1] + (R_slice << 4) → P[1] |
| C6 | 8'h30 | 读 A0(T1)，Ctx0复用 | C10 | acc: P[0] + R_slice → P[0] |
| C7 | 8'h31 | 读 A0(T1)，Ctx1复用 | C11 | acc: P[1] + R_slice → P[1] |
| C8 | 8'h30 | 读 A1(T1)，Ctx0复用 | C12 | fusion: P[0] + (R_slice << 4) → P[0]；输出 |
| C9 | 8'h31 | 读 A1(T1)，Ctx1复用 | C13 | fusion: P[1] + (R_slice << 4) → P[1]；输出 |

Ctx0：末内部发射 C8，raw 完成 C12；Ctx1：末内部发射 C9，raw 完成 C13。

#### precision=4 W4A16
split_mask=7'h01，EN=8'h33，OC_MASK=32'hFFFF_FFFF；D=4T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |
| C9 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C10 | Ctx1，wgt_raddr=8'h31 | A1(T1) |
| C11 | — | A2(T1) |
| C12 | — | A3(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C5 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C6 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C7 | fusion: P[0] + (R_slice << 4) → P[0] |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C8 | fusion: P[1] + (R_slice << 4) → P[1] |
| C5 | 8'h20 | 读 A2(T0)，Ctx0复用 | C9 | fusion: P[0] + (R_slice << 8) → P[0] |
| C6 | 8'h21 | 读 A2(T0)，Ctx1复用 | C10 | fusion: P[1] + (R_slice << 8) → P[1] |
| C7 | 8'h20 | 读 A3(T0)，Ctx0复用 | C11 | fusion: P[0] + (R_slice << 12) → P[0] |
| C8 | 8'h21 | 读 A3(T0)，Ctx1复用 | C12 | fusion: P[1] + (R_slice << 12) → P[1] |
| C10 | 8'h30 | 读 A0(T1)，Ctx0复用 | C14 | acc: P[0] + R_slice → P[0] |
| C11 | 8'h31 | 读 A0(T1)，Ctx1复用 | C15 | acc: P[1] + R_slice → P[1] |
| C12 | 8'h30 | 读 A1(T1)，Ctx0复用 | C16 | fusion: P[0] + (R_slice << 4) → P[0] |
| C13 | 8'h31 | 读 A1(T1)，Ctx1复用 | C17 | fusion: P[1] + (R_slice << 4) → P[1] |
| C14 | 8'h30 | 读 A2(T1)，Ctx0复用 | C18 | fusion: P[0] + (R_slice << 8) → P[0] |
| C15 | 8'h31 | 读 A2(T1)，Ctx1复用 | C19 | fusion: P[1] + (R_slice << 8) → P[1] |
| C16 | 8'h30 | 读 A3(T1)，Ctx0复用 | C20 | fusion: P[0] + (R_slice << 12) → P[0]；输出 |
| C17 | 8'h31 | 读 A3(T1)，Ctx1复用 | C21 | fusion: P[1] + (R_slice << 12) → P[1]；输出 |

Ctx0：末内部发射 C16，raw 完成 C20；Ctx1：末内部发射 C17，raw 完成 C21。

#### precision=5 W8A8
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |
| C5 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C6 | Ctx1，wgt_raddr=8'h31 | A1(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C6 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C7 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C8 | fusion: P[0] + (R_slice << 4) → P[0] |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C9 | fusion: P[1] + (R_slice << 4) → P[1] |
| C6 | 8'h30 | 读 A0(T1)，Ctx0复用 | C11 | acc: P[0] + R_slice → P[0] |
| C7 | 8'h31 | 读 A0(T1)，Ctx1复用 | C12 | acc: P[1] + R_slice → P[1] |
| C8 | 8'h30 | 读 A1(T1)，Ctx0复用 | C13 | fusion: P[0] + (R_slice << 4) → P[0]；输出 |
| C9 | 8'h31 | 读 A1(T1)，Ctx1复用 | C14 | fusion: P[1] + (R_slice << 4) → P[1]；输出 |

Ctx0：末内部发射 C8，raw 完成 C13；Ctx1：末内部发射 C9，raw 完成 C14。

#### precision=6 W8A16
split_mask=7'h00，EN=8'h0F，OC_MASK=32'hFFFF_FFFF；D=5T。

外部输入：

| 外部周期 | i_cmd 与共享权重地址 | ACT |
|---|---|---|
| C0 | Ctx0，wgt_raddr=8'h20 | A0(T0) |
| C1 | Ctx1，wgt_raddr=8'h21 | A1(T0) |
| C2 | — | A2(T0) |
| C3 | — | A3(T0) |
| C9 | Ctx0，wgt_raddr=8'h30 | A0(T1) |
| C10 | Ctx1，wgt_raddr=8'h31 | A1(T1) |
| C11 | — | A2(T1) |
| C12 | — | A3(T1) |

内部发射与运算：

| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |
|---|---|---|---|---|
| C1 | 8'h20 | 读 A0(T0)，Ctx0复用 | C6 | 填充: R_slice → P[0] |
| C2 | 8'h21 | 读 A0(T0)，Ctx1复用 | C7 | 填充: R_slice → P[1] |
| C3 | 8'h20 | 读 A1(T0)，Ctx0复用 | C8 | fusion: P[0] + (R_slice << 4) → P[0] |
| C4 | 8'h21 | 读 A1(T0)，Ctx1复用 | C9 | fusion: P[1] + (R_slice << 4) → P[1] |
| C5 | 8'h20 | 读 A2(T0)，Ctx0复用 | C10 | fusion: P[0] + (R_slice << 8) → P[0] |
| C6 | 8'h21 | 读 A2(T0)，Ctx1复用 | C11 | fusion: P[1] + (R_slice << 8) → P[1] |
| C7 | 8'h20 | 读 A3(T0)，Ctx0复用 | C12 | fusion: P[0] + (R_slice << 12) → P[0] |
| C8 | 8'h21 | 读 A3(T0)，Ctx1复用 | C13 | fusion: P[1] + (R_slice << 12) → P[1] |
| C10 | 8'h30 | 读 A0(T1)，Ctx0复用 | C15 | acc: P[0] + R_slice → P[0] |
| C11 | 8'h31 | 读 A0(T1)，Ctx1复用 | C16 | acc: P[1] + R_slice → P[1] |
| C12 | 8'h30 | 读 A1(T1)，Ctx0复用 | C17 | fusion: P[0] + (R_slice << 4) → P[0] |
| C13 | 8'h31 | 读 A1(T1)，Ctx1复用 | C18 | fusion: P[1] + (R_slice << 4) → P[1] |
| C14 | 8'h30 | 读 A2(T1)，Ctx0复用 | C19 | fusion: P[0] + (R_slice << 8) → P[0] |
| C15 | 8'h31 | 读 A2(T1)，Ctx1复用 | C20 | fusion: P[1] + (R_slice << 8) → P[1] |
| C16 | 8'h30 | 读 A3(T1)，Ctx0复用 | C21 | fusion: P[0] + (R_slice << 12) → P[0]；输出 |
| C17 | 8'h31 | 读 A3(T1)，Ctx1复用 | C22 | fusion: P[1] + (R_slice << 12) → P[1]；输出 |

Ctx0：末内部发射 C16，raw 完成 C21；Ctx1：末内部发射 C17，raw 完成 C22。

## 附录 B 规范 split 编码

以下按 bit6..bit0 给出26种规范编码，K 限制还需结合 precision、EN 和 OC：

`0000000`、`0000001`、`0000011`、`0000101`、`0000111`、`0001011`、`0001111`、`0010011`、`0010111`、`0011011`、`0011111`、`0100101`、`0100111`、`0101111`、`0110111`、`0111111`、`1000101`、`1000111`、`1001111`、`1010111`、`1011111`、`1100101`、`1100111`、`1101111`、`1110111`、`1111111`

Requant的ZP参数均为生成端已round的signed INT32输出域补偿。per-tensor在CIM饱和INT8输出后仅由TB按channel扩位加ZP并再次clip，不再round；per-channel在RTL内先round、加ZP、再clip，TB不重复补偿。完整公式和参考代码转换见[Requant说明](Cluster_Requant.md)及[Block Spec第6.2节](CIM_Block_Spec.docx)。
