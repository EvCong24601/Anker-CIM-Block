# SingleMacro V1.1

实现 [SPEC V1.1](../SingleMacro_SPEC_v1.1.md) 的独立 SystemVerilog 工程。原 `SingleMacro/` 工程保留；本工程的 RTL、测试、脚本和验证快照均在当前目录。

每次计算一个 activation digit Phase，输出四路 signed18。SRAM 读出、同 digit 部分积归约、Weight Fusion 和集中符号补偿共用 R_in→R_out 一拍，Phase II=1。Activation Fusion、跨 Macro 归约及跨 K Tile 的 Psum 由 Cluster 完成。

## 算术实现

1. `MacroPartialProducts2x4` 产生八个受控取反部分积 bit，按 `P=X-C` 编码，不生成独立乘积。OC 无效时在取反后隔离为零。
2. 每 OC 使用一个合并后的 `MacroWeightFusion`，接收四个 t 槽的全部 1024 个部分积 bit。内部函数以组合循环和加法表达式对每个 t 的 32×8 个 bit 作加权归约；各 bit 的列权为 `[0,1,2,3,1,2,3,4]`。局部 unsigned11 数学量 R 的范围为 0…1440。
3. 同一模块内将四个 R 扩宽至 18 bit，再按 W2/W4/W8 位权对齐，与唯一一次补偿 `Q=(-(G<<8)) mod 2^18` 一起求和，取低 18 bit 作为结果。取消独立 digit 归约模块及两行 sum/carry 中间端口，让综合工具在同一算术模块内选择归约和 Fusion 的结构。
4. `MacroSignControl` 在四个 OC 间共享符号和补偿常量译码。无运行时除法或乘法；每 OC 使用与部分积相同的 enable 隔离补偿。

归约与 Fusion 不显式指定 FA/HA/CSA、Dadda/Wallace 层级或连接，不固定加法分组、压缩层数或 CPA 数量，也不依赖 RTL 生成脚本。源码中的固定次数循环描述组合求和，不是逐拍累加；局部变量和函数没有寄存器或 keep/dont_touch 等保留结构约束。实际是否形成预期的压缩网络，须结合综合映射与时序报告判断。

| 文件 | 用途 |
|---|---|
| `rtl/SingleMacro.sv` | 17 个端口、输入输出寄存、SRAM/Hold、四 OC 数据通路 |
| `rtl/single_macro_pkg.sv` | 精度、合法 Phase 和 activation digit 符号规则 |
| `rtl/MacroPartialProducts2x4.sv` | 受控取反及取反后隔离 |
| `rtl/MacroSignControl.sv` | 共享 G/符号/18-bit 补偿字常量译码 |
| `rtl/MacroWeightFusion.sv` | 合并的部分积加权归约、后置位权对齐及集中补偿求和 |
| `rtl/MacroWeightSRAM.sv`、`rtl/MacroClockGate.sv` | 沿用原工程的通用 SRAM 与功能 ICG |
| `rtl/filelist.f` | 合成用源文件列表，不含测试和历史算术单元 |
| `tb/tb_SingleMacro.sv` | 独立整型点积、单拍协议、V0.2/V1.1 逐拍比较 |
| `tb/tb_MacroArithmetic.sv` | 原始部分积列权、四 digit 位权、融合及符号补偿检查 |
| `tb/reference/` | 当前 V0.2 算术及顶层的参考快照，仅用于验证 |
| `scripts/run_tests.py` | SYNTHESIS 分支展开、真实 RTL 功能回归及协议负向测试 |
| `verification/v0.2_source_sha256.json` | 实现前原工程源文件指纹，用于确认原工程未被改动 |

## 接口和状态

模块名 `SingleMacro`，端口及 `USE_CLOCK_GATING` 参数沿用原工程。n 采样、n+1 NBA 后输出，四路 OC 共用一组 512-bit ACT 入口寄存。高有效异步 reset；SRAM 不复位。

`station=1` 使用 SRAM 新读出，并在结果捕获边沿建立完整原始行 Hold。下一笔可以紧邻 `station=0` 复用。任意合法写使 Hold 无效；最后请求 n 后最早 n+2 写，最后写 w 后最早 w+1 读。mask=0 不发射；有结果事务中的屏蔽 OC 输出零；气泡期间输出数据和标签保持。

全部 Weight Fusion 和符号补偿在每次 R_out 前完成。即使总 K>256，外部仍接收已经融合的 Phase Sum，不增加 digit Psum、Context 状态或跨拍算术寄存器。

## 构建和仿真

在本目录执行；Python 仅使用标准库。已有 iverilog/vvp 在 PATH 时可省略工具参数：

```powershell
python -u scripts/run_tests.py --iverilog C:/path/to/iverilog.exe --vvp C:/path/to/vvp.exe
```

本工作区可以只读复用原工程已有的便携仿真器，输出和日志全部写入本工程 `build/`：

```powershell
python -u scripts/run_tests.py --iverilog ../SingleMacro/.tools/iverilog/ucrt64/bin/iverilog.exe --vvp ../SingleMacro/.tools/iverilog/ucrt64/bin/vvp.exe
```

也可以通过继承的 `scripts/bootstrap_iverilog.ps1` 在本目录 `.tools/` 准备独立仿真器。脚本仅对工具子进程设置 DLL 搜索路径，不改系统 PATH。`build/`、`.tools/`、波形和 Python 缓存不进入版本控制。

全部算术 RTL 直接维护，无需运行生成脚本。编译 ASIC 源时使用 `rtl/filelist.f`，不应同时编译旧工程同名顶层。

## 单组可视化仿真

从项目根目录运行：

```powershell
python SingleMacro_v1.1/scripts/visual_single.py
```

默认生成一组 `W8A8 / INT / seed=20261020` 数据：四个 OC 各一行权重，共享一组完整 activation，K=32。脚本先用完整十进制整数计算四路点积 golden，再将权重编码为 SRAM 的 1024-bit 行，将 activation 拆成各 Phase 的 512-bit digit 输入，运行真实 `SingleMacro` RTL。输出以 72-bit 原始 HEX/BIN 和四路 signed18 十进制保存；逐 Phase 比较后，在 Python 中以 `sum(phase_result << (4*phase))` 重建完整点积，再与完整整数 golden 比较。Activation Fusion 是 Python 中模拟的外部操作，不是 Macro 单次接口结果。

脚本仅依赖 Python 标准库，并自动查找 PATH、当前工程或原工程已有的 Icarus。也可显式传入 `--iverilog` 和 `--vvp`。支持七种合法精度、INT/UINT、1～K_row 个有效项、非零 OC mask 和时钟门控开关。例如：

```powershell
python SingleMacro_v1.1/scripts/visual_single.py --mode W8A16 --signedness int --seed 42 --k 8
python SingleMacro_v1.1/scripts/visual_single.py --mode W4A8 --signedness uint --oc-mask 0x5 --clock-gating 0
```

`--k` 之外的权重和 activation 补零。输入数值按所选精度的完整合法整数范围随机生成；INT 使用二进制补码编码。每次仅写一行 SRAM，随后连续发射该 activation 的全部 Phase，`cim_station=1`。testbench 检查结果数量、Phase/mask、未知值及一拍延迟；Python 检查数值相等。任一检查失败均非零退出。

结果默认位于 `build/visual_single/<模式>_<int或uint>_seed<种子>/`，同配置再次运行会更新该目录；可用 `--out` 指定独立目录。打开 `report.html` 可切换 OC、完整点积及各 Phase，查看逐项乘积、累计和、输入编码、原始输出和接口采样时序。

报告顶部还可按 **精度模式、INT/UINT 和仿真记录**切换已完成的实验。`build/visual_single/index.html` 是统一入口。每次运行脚本都会更新 `build/visual_single/`、`build/visual_single_validation/` 及本次输出目录中的报告目录索引，并将各次完整结果内嵌到报告中。切换直接更新本页，不跳转其他文件、不请求网络，也不依赖浏览器读取相邻文件；浏览器不直接启动仿真。

点击“加载本地仿真结果”，可选择其他位置的 `report_data.json` 或已有 `report.html`，支持一次加载多份。数据在浏览器本地读取，不需要 HTTP 服务，也不上传文件。导入后仍可切换 OC、Phase 和查看原始编码；配套 CSV/VCD 请在原输出目录查看。单独的 `results.json` 不含输入和 golden，不能作为完整报告加载。

旧结果可只刷新报告，不重新进行 RTL 仿真：

```powershell
python SingleMacro_v1.1/scripts/visual_single.py --refresh-reports
# 额外收录自定义位置的旧结果：
python SingleMacro_v1.1/scripts/visual_single.py --refresh-reports --out D:/path/to/completed_runs
```

| 文件 | 内容 |
|---|---|
| `weights_decimal.csv`、`act_decimal.csv`、`golden_decimal.csv` | 十进制权重、activation 和理想结果 |
| `inputs_decimal.json` | 模式、种子、mask、有效 K 及全部输入整数，可修改后重放 |
| `golden.json` | 完整整数点积与逐 Phase 理想结果 |
| `encoded_inputs.json`、`stimulus.hex` | 输入总线编码及 testbench 实际读取的激励 |
| `rtl_raw.csv` | RTL 原始 72-bit HEX/BIN、各 OC signed18 十进制、采样周期 |
| `results.json`、`comparison.csv` | 逐 Phase 及完整点积比较 |
| `cycle_trace.csv`、`wave.vcd` | 上升沿后 1 ns 的接口采样及完整 VCD 信号变化 |
| `report.html` | 离线可视化报告，无外部依赖 |
| `report_data.json` | 可单独加载的完整报告数据，含输入、golden、编码、输出及周期记录 |
| `compile.log`、`simulation.log`、`run_manifest.json` | 编译/运行日志、命令及源文件 SHA256 |

重放已保存的数据（重新计算 golden，不信任旧结果）：

```powershell
python SingleMacro_v1.1/scripts/visual_single.py --input-json SingleMacro_v1.1/build/visual_single/W8A8_int_seed20261020/inputs_decimal.json --out SingleMacro_v1.1/build/visual_single/replay
```

报告时序图来自实际采样记录，VCD 另包含入口 valid、activation 符号控制、补偿字、四路组合结果及 OC0 的四组归约值；可用 GTKWave 等查看。该工具用于单组数据的 RTL 功能观察，不用于证明门级延迟或 PPA。

## 验证及物理边界

2026-10-19，使用 Icarus Verilog 13.0 对部分积归约与 WeightFusion 合并的抽象算术版本完成真实 RTL 回归，结果见 [V1.1 验证快照](verification/v1.1_results.json)，详细日志位于 `build/`。四组正向回归均通过：

| 时钟门控 | Seed | 接受请求 | 校验结果 | 复位取消 |
|---|---:|---:|---:|---:|
| 关闭 | 20261013 | 5044 | 5043 | 1 |
| 关闭 | 324508639 | 5051 | 5050 | 1 |
| 开启 | 20261013 | 5044 | 5043 | 1 |
| 开启 | 324508639 | 5051 | 5050 | 1 |
| 合计 | — | 20190 | 20186 | 4 |

每组均穷举 256 种 2×4 输入/符号组合，并检查取反后的隔离；完整回归覆盖七种精度、INT/UINT、全部合法 Phase 和 OC mask、signed 零乘积、每 OC 每 W 模式 256 个逐位权重激励、极值、2,000 次随机调度、一拍输出与标签、气泡保持、异步复位、写入排空、连续刷新和紧邻 Hold 复用。所有输出逐拍与 V0.2 参考实现比较，并使用独立完整整数点积 golden 检查。

独立算术测试通过 5,078 组部分积归约/位权检查，覆盖三种 W 模式下全部 1024 个部分积 bit 的逐位激励、全零/全一和随机输入；另通过 4,500 组包含符号控制与集中补偿的原始部分积向量检查。参考模型逐 bit 按整数列权独立累加，不调用 DUT 的归约函数。13 类非法协议测试全部由新顶层的检查器报告预期错误并非零退出。

K=512 外部调度模型覆盖 W8A16、16 个 K Tile、两个交叠 Context、OS/WS/AS 及 INT/UINT。测试台仅为每 Context/OC 保存一份 64-bit 参考 Psum，跨 Phase 和 K Tile 重建结果与完整 512 项点积一致；宽参考累加器避免把 Cluster 的溢出策略混入本测试。这验证 Macro 边界可沿用既有归约方式，真实 Cluster 的缓存和调度实现仍需集成验证。

原工程全部源文件的 SHA256 与实现前记录一致。新工程的入口/出口寄存、Hold 和协议逻辑与基线逐段核对；SRAM、ICG 和 package 保持原文件内容。参考顶层和原乘法/Fusion 模块仅以 `V02` 前缀重命名，SRAM/ICG/精度辅助函数与新工程共用；参考快照不进入 `rtl/filelist.f`。

每次运行脚本更新 `build/results.json`；`verification/v1.1_results.json` 是上述回归的保存快照，并记录覆盖范围、原工程保持检查、新工程源文件指纹及尚未进行的物理验证。

`SYNTHESIS` 分支编译/展开通过只说明可编译，不等同于逻辑综合。实际 SRAM 和 ICG 尚需工艺适配；没有通过功能仿真证明 256 MHz 或 PPA 提升。STA、门级仿真、PTPX 及真实 Cluster 缓冲/信用和外部电源管理集成需后续验证。
