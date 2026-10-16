# Cluster SystemVerilog testbench

本包以 `CIM_Block_Spec_单Macro定义.docx` 为数值和树拓扑依据，并采用已确认的 **八个 Macro 共用一个 8-bit weight 地址**。不执行 requant，比较完整精度的 raw signed32 Psum。

## 使用

在本目录运行下方的 ModelSim 编译/仿真命令。

也可以直接修改 `tb_Cluster.sv` 顶部的 parameter：

```systemverilog
parameter logic [7:0]  EN_MASK = 8'hff;
parameter logic [31:0] OC_MASK = 32'hffff_ffff;
parameter int OS_TILES = 1;
parameter int PATTERNS = 6;
parameter logic [31:0] SEED = 32'h19e2a407;
```

`EN_MASK[m]` 使能 Macro m。`OC_MASK[4*m+c]` 使能 Macro m 的 OC c，bit0 是 Macro0.OC0，bit31 是 Macro7.OC3。mask 不在回归中自动改变。

编译运行命令（ModelSim 的 vlib/vlog/vsim 需在 PATH 中）：

```text
vlib work
vlog -sv -svinputport=var +define+SINGLE_MACRO_ASSERTIONS -f filelist.f
vsim -c -onfinish stop work.tb_Cluster -do "onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0"
```

`-svinputport=var` 用于兼容现有 Macro 源文件的 `default_nettype none` 与 input logic 声明。仿真完成后确认日志中出现 `PASS configurations=`。

## 覆盖范围与 split_mask

precision 0～6 依次为 W2A4、W2A8、W4A4、W4A8、W4A16、W8A8、W8A16。每种精度分别测试 UINT×UINT 和 INT×INT；不生成混合符号的外部模式。

对 0～127 的 split_mask 逐一检查规范性：根为 bit0，两个四叶节点为 bit1/2，四个二叶节点为 bit3～6；未访问后代位必须为零。共得到 26 种规范树。

每组的判定公式为：

```text
K_row = 256 / weight_bits
K_parallel[group] = popcount(group_macros & EN_MASK) * K_row
保留条件：每个非空组 K_parallel[group] < 256
```

严格排除等于 256 的组。按 EN_MASK 统计 K，不用 OC_MASK 缩减 K；OC mask 仅决定对应通道是否贡献数值及有效位。启用 Macro 在同一组内分配连续、互不重复的 ACT slot；不同输出组复用相同 slot 的输入数据。Idle Macro 的 slot 置零。

全使能时：W2 每种精度 1 种 split（`7'h7f`，八个独立 Macro），W4 每种精度 16 种，W8 每种精度 25 种。结合 signed/unsigned 共 200 个配置，每配置 6 种数据模式，共 1,200 case。部分使能时会重新判定全部 26 种树，因此不能直接使用全使能的静态列表。

每次仿真生成 `split_cases.csv`，逐行列出精度、符号、split_mask、两个 mask、slot 映射、八个组各自的 K。`split_cases_default.csv`、`split_cases_sparse.csv` 是已完成回归的清单。

`verify_manifest.py` 使用独立递归遍历，对 CSV 检查无遗漏、无重复、规范编码、各组 K 和 slot 合法性，不复用 SV 的分组函数：

```text
python verify_manifest.py split_cases_default.csv
```

本测试枚举的是 K_row 粒度的所有规范 split 配置。任意元素数的 K tail 在规格中由上游补零实现，不由 split_mask 表示。

## 数值检查

- 六种模式：随机、全零、最大正数/无符号最大值、最小负数/无符号零、交替极值、W/A 错位符号极值。
- 权重按 `row[256*c + bW*j +: bW]` 装载，每个 Macro 写入独立内容。
- 8-bit 共享读地址随 case 和 K tile 变化，包含地址边界及回绕；同一完整 tile 的各 phase 使用同一地址和内容。
- ACT 使用一个、两个、四个 1024-bit Plane，低 digit 先发。只有最高 activation digit 按 signed 解释；weight signed digit 由现有 Macro RTL 实现。
- scoreboard 从原始整数执行 64-bit `sum(W*A)`，不调用 Macro digit 运算，逐 lane 比较最终 signed32 Psum。
- cmd 与 act 独立握手，交替插入不同空拍，等待 ready 时保持 valid/data；有超时和全局 watchdog。
- 输出强制反压三拍，检查 valid/data/lane mask 保持，再检查无重复输出。

OS_TILES 可增加以检查跨 K Tile 累加。默认取 1，因为 UINT W8A16、K=128、全最大值累加两次会超出 signed32。Overflow 后的处理策略未冻结，本包发现溢出直接报错。已通过的两 Tile 示例使用随机和零模式：

```text
vsim -c -onfinish stop work.tb_Cluster -gOS_TILES=2 -gPATTERNS=2 -gSEED=32'habcde123 -do "onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0"
```

## DUT 接入与明确边界

当前工程没有生产 Cluster 顶层 RTL，因此 `cluster_dut_adapter.sv` 的默认实现是 **8 个现有 SingleMacro RTL + 串行功能调度/归约/Fusion/Psum 参考连接**。实际仿真确实运行了八个 Macro RTL；Cluster 控制逻辑是随本包提供的参考实现。不能将此结果视为尚未提供的生产 Cluster RTL 验证通过。

接入实际 Cluster 时，替换 adapter 内部的实现，保持 testbench 侧接口，或在 adapter 内转换类型和端口：

- `cmd_i`：`cluster_tb_pkg::cluster_ctrl_t`，字段按规格顺序声明。三个计数暂用 16 bit，生产 RTL 位宽不同时在 adapter 显式转换。
- `weight_cim_raddr` **只有 8 bit**，连接到八个 Macro 的 `cim_raddr`。descriptor 不含 macro_id；物理编号由实例连接确定。
- `macro_oc_mask` 为 **32 bit**，采用第 7 章明确的每 Macro 4 bit 布局，覆盖旧字段表的 16-bit 歧义。
- `weight_wen_i[7:0]`、共享写行地址和 `weight_wdata_i[8191:0]` 是 TB 的 preload 接口；每个 Macro 对应连续 1024 bit。实际设计可映射到 SRAM 写端口或后门装载。
- `psum_data_o[32*(4*g+c)+:32]` 与 `psum_lane_valid_o[4*g+c]` 是为跳过 requant 而约定的观测接口。生产 RTL 可暴露 requant 之前的 Psum，或由 adapter 从内部提交事件收集。
- g 按当前树从左到右编号，空组保留无效槽位。若实际 RTL 压缩掉空组，adapter 须还原其结构编号。
- 每个有效组的每个 c，只要存在启用且 OC mask 有效的贡献者，对应输出 lane 有效；整个任务没有有效 OC 时 TB 会报配置错误，不等待未定义的空输出。
- 本轮只运行 OS；`ws_cnt=as_cnt=0`、`os_cnt=OS_TILES`，每个 phase 一条 command。未加入规格表中缺失的 flush_reduce 字段；每个完整 tile 均参与累加。

参考连接逐 phase 收集后再继续发射，用于功能自检。没有验证生产 Cluster 的 II、并行 Context、WS/AS 复用、clock gating、非法命令拒绝或 overflow 恢复策略。

## 已完成验证

ModelSim SE-64 2020.4，启用 SINGLE_MACRO_ASSERTIONS，三组仿真均 PASS：

- EN=ff、OC=ffffffff、OS_TILES=1、六模式：200 配置，1,200 case。
- EN=81、OC=84218421、OS_TILES=1、六模式：360 配置，2,160 case。
- EN=ff、OC=ffffffff、OS_TILES=2、随机及零、第二 seed：200 配置，400 case。

合计 3,760 case。对应日志保存在 `regression_default.log`、`regression_sparse.log`、`regression_os2.log`。默认与部分使能清单均通过独立 Python 枚举检查。

## 文件

- `tb_Cluster.sv`：刺激、split 枚举、scoreboard、握手与输出检查。
- `cluster_tb_pkg.sv`：descriptor 与配置辅助函数。
- `cluster_dut_adapter.sv`：DUT 接入位置及可运行参考连接。
- `filelist.f`：编译顺序，路径相对本目录。
- `verify_manifest.py`：独立检查 split 清单。

源码引用仓库内 `../../macro/rtl/` 中的现有六份 Macro 文件，未修改这些文件。本目录不复制 Macro RTL，直接引用仓库的 macro/rtl。
