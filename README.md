# Anker CIM Block

当前 Cluster 直接输出 raw_psum[1023:0] 和 psum_valid[31:0]，每个物理 lane 为 signed32。Requant 参数、运算、存储及 INT8 输出已移除。

Cluster/Macro/ReduceTree 的功能复位 `reset_n`（原 `reset`）为低有效异步复位。它会复位 MBIST 控制器和测试结果，SRAM 阵列内容保留。上层须在复位期间保持功能 SRAM 访问无效。

接口契约、数值布局和迁移说明见 [Cluster 原始 Psum 输出](docs/Cluster_Raw_Output.md)。

## Cluster 的 SRAM 配置与 MBIST 接口

### SRAM 配置

- `rstn_config`（输入，1 bit）是独立于 `reset_n` 的低有效异步配置复位，清零 SRAM 配置寄存器、8 个 Macro 的本地修复码和 `mbist_repair_done_o`。
- `timing_config_i[7:0]`（输入，8 bit）连接 SRAM 宏的 `timing_config`。Cluster 在 `clock` 上升沿采样后广播到 8 个 Macro 内的全部 16 块 SRAM。
- `waen_i` 和 `raen_i`（输入，各 1 bit）分别连接 SRAM 宏的 `waen` 和 `raen` 配置引脚，采样与广播方式同上。v2 行为模型使用固定访问时序，随附测试平台把这三个配置输入都置零。

### MBIST 启动、状态和修复

- `mbist_macro_id_i[2:0]`（输入，3 bit）选择 Macro 0～7。每次 MBIST 同时测试所选 Macro 的两块 256×512 SRAM，修复写入也用这个 ID 选址。
- `mbist_test_memory_start_i`（输入，1 bit）在 Cluster 空闲时给一个高电平周期，与 Macro ID 同沿采样。
- `mbist_test_busy_o`（输出，1 bit）为 1 表示 Cluster 正在处理本轮 MBIST。`mbist_test_done_o`（输出，1 bit）在寄存后的结果就绪时置 1，并保持到接受下一轮测试或 `reset_n` 复位。启动后先确认本轮 `busy=1`，再等 `done=1` 且 `busy=0` 时读取结果。
- `mbist_test_memory_valid_o`（输出，1 bit）为 1 表示两块 SRAM 的逻辑数据在当前修复映射下均通过。`mbist_out_of_repair_o`（输出，1 bit）为 1 表示至少一块 SRAM 报告超出单个子块的单列修复能力。完成后两个标志均为 0 表示存在可修复的错误。
- `mbist_test_error_sbk_o[63:0]`（输出，64 bit）为本轮所选 Macro 的 8 个子块错误报告。`mbist_test_red_sbk_i[63:0]`（输入，64 bit）为同样布局的修复码。每字节的 bit 7 表示报告有效或使能修复，bits 6:0 是子块内的普通列号（0～127）。
- `mbist_repair_we_i`（输入，1 bit）为 1 的每个 `clock` 上升沿都把完整 64-bit 修复码写入当前 ID 所选 Macro 的本地寄存器。为 0 时各 Macro 保持已有修复码。修复写入和测试启动分别控制。
- `mbist_repair_done_o[7:0]`（输出，8 bit）的 bit M 对应 Macro M。写入沿 N 清零该位，N+3 沿置位。该位保持到同一 Macro 再次写入或 `rstn_config` 复位。这个标志由 Cluster 的固定延迟产生，修复效果通过 MBIST 复测确认。

修复码和错误报告的字节索引均为 `4*bank + sbk`，字节 0 从总线最低位开始。低 512-bit SRAM 对应 `bank=0` 和总线 `[31:0]`，高 512-bit SRAM 对应 `bank=1` 和总线 `[63:32]`。每块 SRAM 的 `sbk=0～3` 按列号从低到高排列，每个子块有 128 根普通位线和一根冗余位线。端口与位序见 [cluster_top.sv](RTL/cluster/rtl/cluster_top.sv) 和 [MacroWeightSRAM.sv](RTL/macro/rtl/MacroWeightSRAM.sv)。

1. 等待计算和功能 SRAM 访问结束，选择 Macro 后发出单周期启动脉冲。忙时暂停新的计算、功能读写和启动请求。
2. 在测试完成时读取状态和错误报告。对可修复的错误，用有效报告字节更新完整修复码，保留其他子块已生效的配置。保持启动为低，用 `mbist_repair_we_i` 写入。
3. 等待所选 Macro 的修复完成位，再发一个启动脉冲复测。MBIST 会覆盖所选 Macro 的 SRAM 内容，恢复计算前须重新装载权重。

## 源码与编译

- RTL/macro/rtl：单 Macro、SRAM、乘法、Slice 融合及门控。
- RTL/cluster/rtl：cluster_top、ClusterReduceTree、共享类型和综合辅助函数。
- RTL/cluster/tb 与 RTL/macro/tb：驱动、独立参考模型、检查函数及场景。
- Cluster 的 *_pkg.sv 保存类型，*_func.sv 在模块内 include。Macro 的 single_macro_pkg.sv 沿用上游常量及函数，详见 [Macro 集成说明](RTL/macro/README.md)。
- lib/blackbox 与 lib/cluster_top.lib：当前 raw 输出的接口模型，Liberty 仅用于接口链接。

从 vcs-rtl 运行 make run CASE=cluster_default。GEMM 示例：make run CASE=gemm_os1_ws32_as1_w8a16_raw。make list 列出当前用例。

仿真编译加 `+define+MACRO_W8_CSA_GOLDEN`，`MacroW8MainTree` 即使用 golden CSA 数学模型，可在没有 HVT FA/HA 仿真库的环境中做功能验证。默认使用固定门级 CSA。定义 `SYNTHESIS` 时也使用固定门级 CSA。以下命令从仓库根目录运行，ModelSim 的 `--csa-golden` 会自动传入该宏。

```sh
make -C vcs-rtl run CASE=cluster_mbist_serial PARAMETERS=+define+MACRO_W8_CSA_GOLDEN
python RTL/cluster/tb/py/run_sram_regression.py --csa-golden --case cluster_mbist_serial
```

Command 为 102 bit，最低位为 `cim_signed_en`，每个任务握手一次。DW 按 K=256 使用完整 ACT 槽：W2/W4/W8 分别启用 2/4/8 个 Macro，通过 OC、split 和 enable mask 控制，无独立的 Macro 内 bit mask。首个 8 bit 权重行地址和首个 1024 bit ACT plane 均可在该沿或之后独立握手。OS/WS/AS count 各为 9 bit，编码 1～511。默认 Psum/权重地址深度为 16，MAX_CONTEXTS=64。

[文档入口](docs/README.md) · [VCS 仿真](vcs-rtl/README.md) · [Macro 规格](RTL/macro/README.md)

[总体控制切换 README](docs/Cluster_Control_Switching_README.md) · [case 切换与 bubble 详细表](docs/Cluster_Control_Switching_README.md#switch-cases)
