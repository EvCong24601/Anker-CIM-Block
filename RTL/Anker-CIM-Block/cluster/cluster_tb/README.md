# Cluster testbench（对齐逐拍输入时序 v2.7）

依据本地规范文档 `CIM_Block_Spec.docx` 和 `CIM_Cluster_逐拍输入时序_v2.7.docx`。
`cluster_dut_adapter.sv` 是连接八个真实 `SingleMacro` RTL 的**仿真参考 Cluster**，不是生产 Cluster RTL。未实现 requant。

## 输出 buffer 深度

在 `tb_Cluster.sv` 设置：

```systemverilog
parameter int OUTPUT_BUFFER_DEPTH = 4;
```

该参数传到 adapter；32 个输出 channel 各有 `OUTPUT_BUFFER_DEPTH` 个 signed32 存储位置，总数据容量为 `32 × OUTPUT_BUFFER_DEPTH × 32 bit`。最小深度为 1，支持非二次幂。

channel 编号为 `4*group_id+oc_id`。每个完成的 Context 占一个向量位置，有效 channel 由 `psum_lane_valid_o` 标识，无效 channel 也保留对应位置。沿用现有整向量 `out_valid_o && out_ready_i` 读出，所有 channel 同时推进，不增加 channel ready、Context 或地址等对外 pin。

在最后 K Tile 的最高 slice 发射前预留输出位置；已在流水中的结果也占 credit。位置不足时通过现有 `cmd_ready_o` 反压；已缓存的 ACT 可等待消费。下游停止读取时，输出数据及 mask 保持。buffer 不承担不同 Context 之间的求和。

## 输入与计算

- 原有端口及 131-bit `cluster_ctrl_t` 保持；读地址是 descriptor 中共享的 8-bit `weight_cim_raddr`，广播到八个 Macro，无独立读地址 pin。
- precision 0..6：W2A4、W2A8、W4A4、W4A8、W4A16、W8A8、W8A16；每种均测 UINT×UINT / INT×INT。
- 每次计算都有 Command，包括 AS 复用 Plane 的拍。Command 与 ACT 可先后独立握手，也可在首拍同拍直接发射。
- ACT 按 A0/A1/A2/A3 输入，分别为完整整数的 `[3:0]` / `[7:4]` / `[11:8]` / `[15:12]`。`act_data_i[4*k+:4]` 是 digit k；INT 仅最高有效 ACT slice 按 signed4 解释。
- WS 顺序：tile → context → phase；AS 顺序：tile → phase → context。AS 每个 Plane 只写一次，消费全部 Context 后才释放。无成功消费时，计数不推进。
- `os_cnt` 表示完整 K Tile 数。Fusion 与 Psum 分别按 Context/channel 存储；只在最高 slice 形成完整 Tile 后更新本 Context 的 Psum。
- 同地址 Weight Hold 有效时使用 `cim_station=0`，首读、换地址、写入后使用 `cim_station=1`。

第四章标准时序保留原 Spec 的 slot：W2=`[0,1,0,1,0,1,0,1]`，W4=`[0,1,2,3,0,1,2,3]`，W8=`[0,1,2,3,4,5,6,7]`；split 分别 `07/01/00`。使用 EN=`55/33/0F` 得到每组 K=128，高 512-bit ACT 补零。

WS 地址依 tile 为 `8'h20 / 8'h30`，tile 内保持。AS 的 T0 Ctx0/1 为 `8'h20/21`，T1 Ctx0/1 为 `8'h30/31`，同 Context 跨 phase 重复该地址。

## 时延和输出含义

实际发射 Cq → Macro C(q+1) → 两拍 reduction C(q+3) → Fusion 与 Psum 同拍更新 C(q+4)。各 Context 的最后 Tile、最高 slice 发射后恰好 4T 出现内部 `raw_psum_valid`；固定流水 II=1。

内部 `raw_psum_valid/raw_context/raw_data` 和 FIFO Context 标签仅供 TB 层次观测，不是对外端口。buffer 排队和下游等待不改变内部 4T，但会增加外部读取时延。

为保持已有 TB 端口，本参考 adapter 的 `psum_data_o/out_valid_o` 运输 requant 前的 raw signed32 向量。**这不是原 Spec 6.1 的 requant 后 out_valid 语义**；接入生产 DUT 时需映射到其内部 raw 结果观测点，不能据此认定量化接口已验证。

接口按 v2.7 使用共享读地址和 32-bit OC mask。完整 Tile 融合完成后更新对应 Context 的 Psum。溢出时报错，不虚构饱和策略。当前每个 Context 的存活 Fusion/Psum 容量由内部参数 `MAX_CONTEXTS=16` 限定，与输出 buffer 深度独立。

## 回归

从本目录运行（ModelSim 的 `vlib/vlog/vsim` 在 PATH）：

```text
python run_regression.py
python run_regression.py --depth 1 --patterns 2 --log regression_depth1.log
python run_regression.py --depth 3 --os 2 --patterns 2 --log regression_depth3.log
python run_regression.py --en 81 --oc 84218421 --patterns 2 --log regression_sparse.log
```

也可直接 `vlog -sv -svinputport=var +define+SINGLE_MACRO_ASSERTIONS -f filelist.f`，再 `vsim -c work.tb_Cluster -gOUTPUT_BUFFER_DEPTH=3 -do "run -all; quit -f"`。Python runner 会检查 PASS 及 Fatal/Error，避免仅凭 vsim 的退出码误判。

默认 EN=FF 时，每个符号下的合法 split 数依 precision 0..6 为 `1,1,16,16,16,25,25`，合计 200 个 signed/unsigned 配置。枚举所有 26 种规范树，保留每个组启用 Macro 数 × K_row **严格小于 256** 的配置；不因 OC mask 而减少 K。`split_cases.csv` 记录配置，`verify_manifest.py` 使用独立递归树算法检查完整性。

穷举 suite 为每个组生成互异、合法的 slot；这部分使用组内启用成员的 rank，不冒充标准 slot 映射。另有独立的标准映射 suite，逐精度/符号执行 v2.7 第四章六组 OS/WS/AS 时序。

默认 6 种数据模式：随机、零、最大正值、最小负值、交替极值、W/A 错位极值。UINT W8A16 的 ACT 限制到 `0..32768/os_cnt-1`，使完整 Psum 保持 signed32；这不是 DUT 截断或饱和，也不覆盖溢出处理策略。

默认共 1312 case：1200 个穷举数据 case + 84 个标准时序 case + 28 个 buffer/握手压力 case。压力 suite 分别使用 WS/AS，Context 数取 `min(OUTPUT_BUFFER_DEPTH+2,16)`，检查满载、回绕、读写并发、顺序、背压稳定和不丢失；深度 ≥16 时不保证达到满载。深度为 1 时标准 suite 允许容量引起的等待，4T 仍从实际发射计起。

scoreboard 使用完整 W×ACT 整数点积，不复用 DUT 的 bit-slice fusion 算法；组映射采用独立递归解码。并检查 descriptor 地址、phase/context/tile 顺序、AS Plane 生命周期、Macro 元数据、Context 独立结果、4T、输入与输出反压稳定、最终 FIFO 排空。

EN_MASK/OC_MASK 可在顶层用 parameter 或 runner 的 `--en/--oc` 设置；至少需要一个有效输出 OC。`OS_TILES` 用于穷举 suite，当前范围 1..14，确保 preload 的 tile/context 行号互不覆盖。六组标准时序固定使用文档的 os=1/2，不受该参数影响。

RTL 依赖路径见 `filelist.f`：`../../macro/rtl/`。移植时仅需改这些路径。已有旧日期日志和 manifest 快照属于旧版串行 TB，当前结果见 `regression_v27_*.log`。
