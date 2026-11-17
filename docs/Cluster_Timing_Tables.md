# Cluster 当前逐拍写入表

外部命令为 102 bit，每任务握手一次；权重地址和 ACT 独立握手。

[流水总览](Cluster_Pipeline.svg) · [实测交接图](Cluster_Issue_Timing.svg) · [输入调度](Cluster_Input_Overlap.md) · [接口契约](Cluster_Raw_Output.md)

## 周期口径

以下 42 组以任务首次内部 issue 为 C0，假定操作数及时供给、各次 issue 连续。C0 不代表命令或 ACT 的外部接收沿。输入等待会移动后续 issue，写入及发布沿须按该笔实际 issue 计算。

相对每次 issue：输入 I0、CSA I1、Macro 结果 I2。Reduce-1/2、Reduce-4、Reduce-8 在 I3/I4/I5 写 tmp；需要 Psum 时下一沿写回。归约宽度取决于 split 结构端点，不能按 enable 的 popcount 或仅按 W 精度推断。

“发布”为最终值写入后 psum_valid 拉高的沿，“采样”为下一上升沿。非最终 phase/Tile 只更新历史。TMP 模式为 OS=AS=1；OS Psum 为 OS>1 且 AS=1；AS Psum 为 AS>1。WS 不独立增加写回一级。

AS 按 Tile→phase→Context 发射，每 phase 写 Psum；其他模式按 Tile→Context→phase 发射，在 tmp 前融合，OS Psum 只在末 phase 写回。所有中间存储均须适合 signed32，没有硬件饱和保护。

## 42 组标准示例

K128 示例采用 W2 split=07/EN=55、W4 split=01/EN=33、W8 split=00/EN=0F，结构端点分别为 2/4/8 路，OC mask=FFFFFFFF。每 Tile K=128，总 K=128×OS；物理行尾部补零。完整 K256 槽映射见接口契约。

### A1 precision=0 W2A4 OS=1 WS=1 AS=1

split=7'h07，EN=8'h55，issue→tmp=3 拍。命令 1 次、地址 1 次、ACT plane 1 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C3 | — | C3 | C4 |

### A1 precision=1 W2A8 OS=1 WS=1 AS=1

split=7'h07，EN=8'h55，issue→tmp=3 拍。命令 1 次、地址 1 次、ACT plane 2 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C3 | — | — | — |
| C1 | 0 | 0 | 1 | C4 | — | C4 | C5 |

### A1 precision=2 W4A4 OS=1 WS=1 AS=1

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 1 次、ACT plane 1 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | — | C4 | C5 |

### A1 precision=3 W4A8 OS=1 WS=1 AS=1

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 1 次、ACT plane 2 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | — | — | — |
| C1 | 0 | 0 | 1 | C5 | — | C5 | C6 |

### A1 precision=4 W4A16 OS=1 WS=1 AS=1

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 1 次、ACT plane 4 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | — | — | — |
| C1 | 0 | 0 | 1 | C5 | — | — | — |
| C2 | 0 | 0 | 2 | C6 | — | — | — |
| C3 | 0 | 0 | 3 | C7 | — | C7 | C8 |

### A1 precision=5 W8A8 OS=1 WS=1 AS=1

split=7'h00，EN=8'h0F，issue→tmp=5 拍。命令 1 次、地址 1 次、ACT plane 2 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C5 | — | — | — |
| C1 | 0 | 0 | 1 | C6 | — | C6 | C7 |

### A1 precision=6 W8A16 OS=1 WS=1 AS=1

split=7'h00，EN=8'h0F，issue→tmp=5 拍。命令 1 次、地址 1 次、ACT plane 4 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C5 | — | — | — |
| C1 | 0 | 0 | 1 | C6 | — | — | — |
| C2 | 0 | 0 | 2 | C7 | — | — | — |
| C3 | 0 | 0 | 3 | C8 | — | C8 | C9 |

### A2 precision=0 W2A4 OS=1 WS=1 AS=2

split=7'h07，EN=8'h55，issue→tmp=3 拍。命令 1 次、地址 2 次、ACT plane 1 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C3 | C4 | C4 | C5 |
| C1 | 0 | 1 | 0 | C4 | C5 | C5 | C6 |

### A2 precision=1 W2A8 OS=1 WS=1 AS=2

split=7'h07，EN=8'h55，issue→tmp=3 拍。命令 1 次、地址 2 次、ACT plane 2 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C3 | C4 | — | — |
| C1 | 0 | 1 | 0 | C4 | C5 | — | — |
| C2 | 0 | 0 | 1 | C5 | C6 | C6 | C7 |
| C3 | 0 | 1 | 1 | C6 | C7 | C7 | C8 |

### A2 precision=2 W4A4 OS=1 WS=1 AS=2

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 2 次、ACT plane 1 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | C5 | C5 | C6 |
| C1 | 0 | 1 | 0 | C5 | C6 | C6 | C7 |

### A2 precision=3 W4A8 OS=1 WS=1 AS=2

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 2 次、ACT plane 2 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | C5 | — | — |
| C1 | 0 | 1 | 0 | C5 | C6 | — | — |
| C2 | 0 | 0 | 1 | C6 | C7 | C7 | C8 |
| C3 | 0 | 1 | 1 | C7 | C8 | C8 | C9 |

### A2 precision=4 W4A16 OS=1 WS=1 AS=2

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 2 次、ACT plane 4 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | C5 | — | — |
| C1 | 0 | 1 | 0 | C5 | C6 | — | — |
| C2 | 0 | 0 | 1 | C6 | C7 | — | — |
| C3 | 0 | 1 | 1 | C7 | C8 | — | — |
| C4 | 0 | 0 | 2 | C8 | C9 | — | — |
| C5 | 0 | 1 | 2 | C9 | C10 | — | — |
| C6 | 0 | 0 | 3 | C10 | C11 | C11 | C12 |
| C7 | 0 | 1 | 3 | C11 | C12 | C12 | C13 |

### A2 precision=5 W8A8 OS=1 WS=1 AS=2

split=7'h00，EN=8'h0F，issue→tmp=5 拍。命令 1 次、地址 2 次、ACT plane 2 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C5 | C6 | — | — |
| C1 | 0 | 1 | 0 | C6 | C7 | — | — |
| C2 | 0 | 0 | 1 | C7 | C8 | C8 | C9 |
| C3 | 0 | 1 | 1 | C8 | C9 | C9 | C10 |

### A2 precision=6 W8A16 OS=1 WS=1 AS=2

split=7'h00，EN=8'h0F，issue→tmp=5 拍。命令 1 次、地址 2 次、ACT plane 4 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C5 | C6 | — | — |
| C1 | 0 | 1 | 0 | C6 | C7 | — | — |
| C2 | 0 | 0 | 1 | C7 | C8 | — | — |
| C3 | 0 | 1 | 1 | C8 | C9 | — | — |
| C4 | 0 | 0 | 2 | C9 | C10 | — | — |
| C5 | 0 | 1 | 2 | C10 | C11 | — | — |
| C6 | 0 | 0 | 3 | C11 | C12 | C12 | C13 |
| C7 | 0 | 1 | 3 | C12 | C13 | C13 | C14 |

### A3 precision=0 W2A4 OS=1 WS=2 AS=1

split=7'h07，EN=8'h55，issue→tmp=3 拍。命令 1 次、地址 1 次、ACT plane 2 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C3 | — | C3 | C4 |
| C1 | 0 | 1 | 0 | C4 | — | C4 | C5 |

### A3 precision=1 W2A8 OS=1 WS=2 AS=1

split=7'h07，EN=8'h55，issue→tmp=3 拍。命令 1 次、地址 1 次、ACT plane 4 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C3 | — | — | — |
| C1 | 0 | 0 | 1 | C4 | — | C4 | C5 |
| C2 | 0 | 1 | 0 | C5 | — | — | — |
| C3 | 0 | 1 | 1 | C6 | — | C6 | C7 |

### A3 precision=2 W4A4 OS=1 WS=2 AS=1

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 1 次、ACT plane 2 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | — | C4 | C5 |
| C1 | 0 | 1 | 0 | C5 | — | C5 | C6 |

### A3 precision=3 W4A8 OS=1 WS=2 AS=1

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 1 次、ACT plane 4 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | — | — | — |
| C1 | 0 | 0 | 1 | C5 | — | C5 | C6 |
| C2 | 0 | 1 | 0 | C6 | — | — | — |
| C3 | 0 | 1 | 1 | C7 | — | C7 | C8 |

### A3 precision=4 W4A16 OS=1 WS=2 AS=1

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 1 次、ACT plane 8 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | — | — | — |
| C1 | 0 | 0 | 1 | C5 | — | — | — |
| C2 | 0 | 0 | 2 | C6 | — | — | — |
| C3 | 0 | 0 | 3 | C7 | — | C7 | C8 |
| C4 | 0 | 1 | 0 | C8 | — | — | — |
| C5 | 0 | 1 | 1 | C9 | — | — | — |
| C6 | 0 | 1 | 2 | C10 | — | — | — |
| C7 | 0 | 1 | 3 | C11 | — | C11 | C12 |

### A3 precision=5 W8A8 OS=1 WS=2 AS=1

split=7'h00，EN=8'h0F，issue→tmp=5 拍。命令 1 次、地址 1 次、ACT plane 4 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C5 | — | — | — |
| C1 | 0 | 0 | 1 | C6 | — | C6 | C7 |
| C2 | 0 | 1 | 0 | C7 | — | — | — |
| C3 | 0 | 1 | 1 | C8 | — | C8 | C9 |

### A3 precision=6 W8A16 OS=1 WS=2 AS=1

split=7'h00，EN=8'h0F，issue→tmp=5 拍。命令 1 次、地址 1 次、ACT plane 8 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C5 | — | — | — |
| C1 | 0 | 0 | 1 | C6 | — | — | — |
| C2 | 0 | 0 | 2 | C7 | — | — | — |
| C3 | 0 | 0 | 3 | C8 | — | C8 | C9 |
| C4 | 0 | 1 | 0 | C9 | — | — | — |
| C5 | 0 | 1 | 1 | C10 | — | — | — |
| C6 | 0 | 1 | 2 | C11 | — | — | — |
| C7 | 0 | 1 | 3 | C12 | — | C12 | C13 |

### A4 precision=0 W2A4 OS=2 WS=1 AS=1

split=7'h07，EN=8'h55，issue→tmp=3 拍。命令 1 次、地址 2 次、ACT plane 2 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C3 | C4 | — | — |
| C1 | 1 | 0 | 0 | C4 | C5 | C5 | C6 |

### A4 precision=1 W2A8 OS=2 WS=1 AS=1

split=7'h07，EN=8'h55，issue→tmp=3 拍。命令 1 次、地址 2 次、ACT plane 4 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C3 | — | — | — |
| C1 | 0 | 0 | 1 | C4 | C5 | — | — |
| C2 | 1 | 0 | 0 | C5 | — | — | — |
| C3 | 1 | 0 | 1 | C6 | C7 | C7 | C8 |

### A4 precision=2 W4A4 OS=2 WS=1 AS=1

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 2 次、ACT plane 2 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | C5 | — | — |
| C1 | 1 | 0 | 0 | C5 | C6 | C6 | C7 |

### A4 precision=3 W4A8 OS=2 WS=1 AS=1

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 2 次、ACT plane 4 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | — | — | — |
| C1 | 0 | 0 | 1 | C5 | C6 | — | — |
| C2 | 1 | 0 | 0 | C6 | — | — | — |
| C3 | 1 | 0 | 1 | C7 | C8 | C8 | C9 |

### A4 precision=4 W4A16 OS=2 WS=1 AS=1

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 2 次、ACT plane 8 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | — | — | — |
| C1 | 0 | 0 | 1 | C5 | — | — | — |
| C2 | 0 | 0 | 2 | C6 | — | — | — |
| C3 | 0 | 0 | 3 | C7 | C8 | — | — |
| C4 | 1 | 0 | 0 | C8 | — | — | — |
| C5 | 1 | 0 | 1 | C9 | — | — | — |
| C6 | 1 | 0 | 2 | C10 | — | — | — |
| C7 | 1 | 0 | 3 | C11 | C12 | C12 | C13 |

### A4 precision=5 W8A8 OS=2 WS=1 AS=1

split=7'h00，EN=8'h0F，issue→tmp=5 拍。命令 1 次、地址 2 次、ACT plane 4 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C5 | — | — | — |
| C1 | 0 | 0 | 1 | C6 | C7 | — | — |
| C2 | 1 | 0 | 0 | C7 | — | — | — |
| C3 | 1 | 0 | 1 | C8 | C9 | C9 | C10 |

### A4 precision=6 W8A16 OS=2 WS=1 AS=1

split=7'h00，EN=8'h0F，issue→tmp=5 拍。命令 1 次、地址 2 次、ACT plane 8 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C5 | — | — | — |
| C1 | 0 | 0 | 1 | C6 | — | — | — |
| C2 | 0 | 0 | 2 | C7 | — | — | — |
| C3 | 0 | 0 | 3 | C8 | C9 | — | — |
| C4 | 1 | 0 | 0 | C9 | — | — | — |
| C5 | 1 | 0 | 1 | C10 | — | — | — |
| C6 | 1 | 0 | 2 | C11 | — | — | — |
| C7 | 1 | 0 | 3 | C12 | C13 | C13 | C14 |

### A5 precision=0 W2A4 OS=2 WS=2 AS=1

split=7'h07，EN=8'h55，issue→tmp=3 拍。命令 1 次、地址 2 次、ACT plane 4 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C3 | C4 | — | — |
| C1 | 0 | 1 | 0 | C4 | C5 | — | — |
| C2 | 1 | 0 | 0 | C5 | C6 | C6 | C7 |
| C3 | 1 | 1 | 0 | C6 | C7 | C7 | C8 |

### A5 precision=1 W2A8 OS=2 WS=2 AS=1

split=7'h07，EN=8'h55，issue→tmp=3 拍。命令 1 次、地址 2 次、ACT plane 8 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C3 | — | — | — |
| C1 | 0 | 0 | 1 | C4 | C5 | — | — |
| C2 | 0 | 1 | 0 | C5 | — | — | — |
| C3 | 0 | 1 | 1 | C6 | C7 | — | — |
| C4 | 1 | 0 | 0 | C7 | — | — | — |
| C5 | 1 | 0 | 1 | C8 | C9 | C9 | C10 |
| C6 | 1 | 1 | 0 | C9 | — | — | — |
| C7 | 1 | 1 | 1 | C10 | C11 | C11 | C12 |

### A5 precision=2 W4A4 OS=2 WS=2 AS=1

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 2 次、ACT plane 4 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | C5 | — | — |
| C1 | 0 | 1 | 0 | C5 | C6 | — | — |
| C2 | 1 | 0 | 0 | C6 | C7 | C7 | C8 |
| C3 | 1 | 1 | 0 | C7 | C8 | C8 | C9 |

### A5 precision=3 W4A8 OS=2 WS=2 AS=1

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 2 次、ACT plane 8 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | — | — | — |
| C1 | 0 | 0 | 1 | C5 | C6 | — | — |
| C2 | 0 | 1 | 0 | C6 | — | — | — |
| C3 | 0 | 1 | 1 | C7 | C8 | — | — |
| C4 | 1 | 0 | 0 | C8 | — | — | — |
| C5 | 1 | 0 | 1 | C9 | C10 | C10 | C11 |
| C6 | 1 | 1 | 0 | C10 | — | — | — |
| C7 | 1 | 1 | 1 | C11 | C12 | C12 | C13 |

### A5 precision=4 W4A16 OS=2 WS=2 AS=1

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 2 次、ACT plane 16 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | — | — | — |
| C1 | 0 | 0 | 1 | C5 | — | — | — |
| C2 | 0 | 0 | 2 | C6 | — | — | — |
| C3 | 0 | 0 | 3 | C7 | C8 | — | — |
| C4 | 0 | 1 | 0 | C8 | — | — | — |
| C5 | 0 | 1 | 1 | C9 | — | — | — |
| C6 | 0 | 1 | 2 | C10 | — | — | — |
| C7 | 0 | 1 | 3 | C11 | C12 | — | — |
| C8 | 1 | 0 | 0 | C12 | — | — | — |
| C9 | 1 | 0 | 1 | C13 | — | — | — |
| C10 | 1 | 0 | 2 | C14 | — | — | — |
| C11 | 1 | 0 | 3 | C15 | C16 | C16 | C17 |
| C12 | 1 | 1 | 0 | C16 | — | — | — |
| C13 | 1 | 1 | 1 | C17 | — | — | — |
| C14 | 1 | 1 | 2 | C18 | — | — | — |
| C15 | 1 | 1 | 3 | C19 | C20 | C20 | C21 |

### A5 precision=5 W8A8 OS=2 WS=2 AS=1

split=7'h00，EN=8'h0F，issue→tmp=5 拍。命令 1 次、地址 2 次、ACT plane 8 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C5 | — | — | — |
| C1 | 0 | 0 | 1 | C6 | C7 | — | — |
| C2 | 0 | 1 | 0 | C7 | — | — | — |
| C3 | 0 | 1 | 1 | C8 | C9 | — | — |
| C4 | 1 | 0 | 0 | C9 | — | — | — |
| C5 | 1 | 0 | 1 | C10 | C11 | C11 | C12 |
| C6 | 1 | 1 | 0 | C11 | — | — | — |
| C7 | 1 | 1 | 1 | C12 | C13 | C13 | C14 |

### A5 precision=6 W8A16 OS=2 WS=2 AS=1

split=7'h00，EN=8'h0F，issue→tmp=5 拍。命令 1 次、地址 2 次、ACT plane 16 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C5 | — | — | — |
| C1 | 0 | 0 | 1 | C6 | — | — | — |
| C2 | 0 | 0 | 2 | C7 | — | — | — |
| C3 | 0 | 0 | 3 | C8 | C9 | — | — |
| C4 | 0 | 1 | 0 | C9 | — | — | — |
| C5 | 0 | 1 | 1 | C10 | — | — | — |
| C6 | 0 | 1 | 2 | C11 | — | — | — |
| C7 | 0 | 1 | 3 | C12 | C13 | — | — |
| C8 | 1 | 0 | 0 | C13 | — | — | — |
| C9 | 1 | 0 | 1 | C14 | — | — | — |
| C10 | 1 | 0 | 2 | C15 | — | — | — |
| C11 | 1 | 0 | 3 | C16 | C17 | C17 | C18 |
| C12 | 1 | 1 | 0 | C17 | — | — | — |
| C13 | 1 | 1 | 1 | C18 | — | — | — |
| C14 | 1 | 1 | 2 | C19 | — | — | — |
| C15 | 1 | 1 | 3 | C20 | C21 | C21 | C22 |

### A6 precision=0 W2A4 OS=2 WS=1 AS=2

split=7'h07，EN=8'h55，issue→tmp=3 拍。命令 1 次、地址 4 次、ACT plane 2 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C3 | C4 | — | — |
| C1 | 0 | 1 | 0 | C4 | C5 | — | — |
| C2 | 1 | 0 | 0 | C5 | C6 | C6 | C7 |
| C3 | 1 | 1 | 0 | C6 | C7 | C7 | C8 |

### A6 precision=1 W2A8 OS=2 WS=1 AS=2

split=7'h07，EN=8'h55，issue→tmp=3 拍。命令 1 次、地址 4 次、ACT plane 4 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C3 | C4 | — | — |
| C1 | 0 | 1 | 0 | C4 | C5 | — | — |
| C2 | 0 | 0 | 1 | C5 | C6 | — | — |
| C3 | 0 | 1 | 1 | C6 | C7 | — | — |
| C4 | 1 | 0 | 0 | C7 | C8 | — | — |
| C5 | 1 | 1 | 0 | C8 | C9 | — | — |
| C6 | 1 | 0 | 1 | C9 | C10 | C10 | C11 |
| C7 | 1 | 1 | 1 | C10 | C11 | C11 | C12 |

### A6 precision=2 W4A4 OS=2 WS=1 AS=2

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 4 次、ACT plane 2 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | C5 | — | — |
| C1 | 0 | 1 | 0 | C5 | C6 | — | — |
| C2 | 1 | 0 | 0 | C6 | C7 | C7 | C8 |
| C3 | 1 | 1 | 0 | C7 | C8 | C8 | C9 |

### A6 precision=3 W4A8 OS=2 WS=1 AS=2

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 4 次、ACT plane 4 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | C5 | — | — |
| C1 | 0 | 1 | 0 | C5 | C6 | — | — |
| C2 | 0 | 0 | 1 | C6 | C7 | — | — |
| C3 | 0 | 1 | 1 | C7 | C8 | — | — |
| C4 | 1 | 0 | 0 | C8 | C9 | — | — |
| C5 | 1 | 1 | 0 | C9 | C10 | — | — |
| C6 | 1 | 0 | 1 | C10 | C11 | C11 | C12 |
| C7 | 1 | 1 | 1 | C11 | C12 | C12 | C13 |

### A6 precision=4 W4A16 OS=2 WS=1 AS=2

split=7'h01，EN=8'h33，issue→tmp=4 拍。命令 1 次、地址 4 次、ACT plane 8 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C4 | C5 | — | — |
| C1 | 0 | 1 | 0 | C5 | C6 | — | — |
| C2 | 0 | 0 | 1 | C6 | C7 | — | — |
| C3 | 0 | 1 | 1 | C7 | C8 | — | — |
| C4 | 0 | 0 | 2 | C8 | C9 | — | — |
| C5 | 0 | 1 | 2 | C9 | C10 | — | — |
| C6 | 0 | 0 | 3 | C10 | C11 | — | — |
| C7 | 0 | 1 | 3 | C11 | C12 | — | — |
| C8 | 1 | 0 | 0 | C12 | C13 | — | — |
| C9 | 1 | 1 | 0 | C13 | C14 | — | — |
| C10 | 1 | 0 | 1 | C14 | C15 | — | — |
| C11 | 1 | 1 | 1 | C15 | C16 | — | — |
| C12 | 1 | 0 | 2 | C16 | C17 | — | — |
| C13 | 1 | 1 | 2 | C17 | C18 | — | — |
| C14 | 1 | 0 | 3 | C18 | C19 | C19 | C20 |
| C15 | 1 | 1 | 3 | C19 | C20 | C20 | C21 |

### A6 precision=5 W8A8 OS=2 WS=1 AS=2

split=7'h00，EN=8'h0F，issue→tmp=5 拍。命令 1 次、地址 4 次、ACT plane 4 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C5 | C6 | — | — |
| C1 | 0 | 1 | 0 | C6 | C7 | — | — |
| C2 | 0 | 0 | 1 | C7 | C8 | — | — |
| C3 | 0 | 1 | 1 | C8 | C9 | — | — |
| C4 | 1 | 0 | 0 | C9 | C10 | — | — |
| C5 | 1 | 1 | 0 | C10 | C11 | — | — |
| C6 | 1 | 0 | 1 | C11 | C12 | C12 | C13 |
| C7 | 1 | 1 | 1 | C12 | C13 | C13 | C14 |

### A6 precision=6 W8A16 OS=2 WS=1 AS=2

split=7'h00，EN=8'h0F，issue→tmp=5 拍。命令 1 次、地址 4 次、ACT plane 8 次。

| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |
|---|---:|---:|---:|---|---|---|---|
| C0 | 0 | 0 | 0 | C5 | C6 | — | — |
| C1 | 0 | 1 | 0 | C6 | C7 | — | — |
| C2 | 0 | 0 | 1 | C7 | C8 | — | — |
| C3 | 0 | 1 | 1 | C8 | C9 | — | — |
| C4 | 0 | 0 | 2 | C9 | C10 | — | — |
| C5 | 0 | 1 | 2 | C10 | C11 | — | — |
| C6 | 0 | 0 | 3 | C11 | C12 | — | — |
| C7 | 0 | 1 | 3 | C12 | C13 | — | — |
| C8 | 1 | 0 | 0 | C13 | C14 | — | — |
| C9 | 1 | 1 | 0 | C14 | C15 | — | — |
| C10 | 1 | 0 | 1 | C15 | C16 | — | — |
| C11 | 1 | 1 | 1 | C16 | C17 | — | — |
| C12 | 1 | 0 | 2 | C17 | C18 | — | — |
| C13 | 1 | 1 | 2 | C18 | C19 | — | — |
| C14 | 1 | 0 | 3 | C19 | C20 | C20 | C21 |
| C15 | 1 | 1 | 3 | C20 | C21 | C21 | C22 |

## 连续任务

兼容性检查覆盖当前输入任务、全部实际在途事务和待写回的 Psum tmp。兼容新 cmd 最早在旧任务末次 issue 沿接收，首操作数及时到达时下一沿 issue。要求同 A 位宽、同累加模式，以及同 split 或单一有效归约宽度下的同路径类别。混合宽度仅保留同 split 规则；空任务不能掩盖更早的在途约束。

不兼容配置等待旧结果排空，最早在采样最后一个旧结果的同沿接收新 cmd。精确规则见 [控制切换说明](Cluster_Control_Switching_README.md)。

生成器：`python RTL/cluster/tb/py/generate_readme.py`。不调用旧 combined-command 的 buffer_schedule.py 或 audit_latency.py。
