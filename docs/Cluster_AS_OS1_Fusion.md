# OS1 AS bit fusion 与权重地址暂存

仅当 `os_cnt=1 && as_cnt>1` 时，AS 采用 Context→Slice：一个 Context 的全部 ACT slice 连续完成 bit fusion 后，再切换下一个 Context。`os_cnt>1` 的 AS 保留 Slice→Context，融合历史和跨 Tile 累加仍放在 Psum。

## OS1 的数据路径

同一份完整 ACT 保存在 4096-bit bank 中，供全部 AS Context 使用。每个 OC 仍只有一个 32-bit tmp：A0 的归约结果覆盖 tmp，后续 slice 在 tmp 前做 `tmp + (R_slice << (4*phase))`。最后一个 slice 融合完成后发布结果，下一个 Context 从 A0 重新开始，互不相加。所有 OS1 精度均不读写 Psum，Psum 时钟整批关闭。

这不是把 bit fusion 移入 SingleMacro；融合仍在 Cluster 归约终点与唯一 tmp 之间，OS1 AS 与现有 WS 共用该组合块。标准 W2/W4/W8 从末次内部发射到 raw 仍为 3/4/5T。归约末级与 fusion 的组合路径仍需后续综合/STA 确认。

## 所有 AS 共用的地址表

```systemverilog
parameter int WGT_RADDR_BUFFER_DEPTH = 64;
logic [7:0] context_address [0:WGT_RADDR_BUFFER_DEPTH-1];
```

地址表保存每个 Context 的 `weight_cim_raddr`，总容量为 64×8=512 bit，即 64 B。它不保存权重行数据。外部仍在每个 Tile 为各 Context 提交地址命令，按接受顺序填表；当前 Context 的地址已收到，才允许内部发射。新 Tile 可提交不同地址，在旧包末次发射之后才开始换入。

**OS1 AS 和 OS>1 AS 都使用该表。**两者读取方式不同：

- OS1：Context0 的 A0..A(P−1) 使用地址0，随后 Context1 的全部 slice 使用地址1，依此类推。Macro 可以在同一 Context 内复用权重 Hold。
- OS>1：A0 遍历所有 Context 地址，再从地址0开始遍历 A1，依此类推。后续 slice 仍需重访之前 Context 的地址，因此也必须保存地址表。

计算端的行地址对八个 Macro 广播，每个 Macro 从自己的 SRAM 取该行；无需为八个 Macro 各保存一份地址表。

## 容量参数

- `WGT_RADDR_BUFFER_DEPTH` 默认 64：仅控制 AS 的 8-bit 行地址表深度。
- `MAX_CONTEXTS` 默认 64：控制 Context 标签与完成状态容量，不是 Psum 数据深度。
- `OUTPUT_BUFFER_DEPTH` 默认 16：控制每 OC 的 32-bit Psum Context entry 数，仅 OS>1 使用。

OS1 AS64 的七种精度全部合法；OS2 AS8 合法，OS2 AS64 因需要 64 项 Psum 而被拒绝。地址深度或标签容量单独配置为 32 时，OS1 AS64 也会因相应资源不足被拒绝。所有容量错误均在首命令接受时检查。

## A16 OS1 AS2 示例

- C0：接受 Context0 地址与 A0。
- C1：接受 Context1 地址与 A1，同时发射 Context0/A0。
- C2：接受 A2，发射 Context0/A1。
- C3：接受 A3，发射 Context0/A2。
- C4：发射 Context0/A3。
- C5..C8：依次发射 Context1/A0..A3。

若 Context1 地址延迟到 C5 才接受，Context0 仍在 C1..C4 完成发射；C5 等待地址，C6..C9 发射 Context1。ACT 采样、已有输入发射、后续地址接收仍可重叠，不等待整包收齐。

无空拍时，OS1 AS 的发射周期为 `S+1+c*P+phase`；OS>1 AS 保留 `S+1+phase*R+c`。AS 包起点仍为 `S=Tile*(1+R*P)`，整包有效发射数仍为 R×P，但 Context 输出的先后周期可能变化。

## 验证入口

仿真使用 [VCS case 入口](../vcs-rtl/README.md)，支持独立编译、数据生成、运行及结果检查。