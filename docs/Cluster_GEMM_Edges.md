# GEMM 高位置组 尾部与量化边界测试

tb_Cluster_GEMM_Edges.sv新增四类端到端矩阵场景。均通过WLC常规128B端口写入/读回真实权重SRAM，再发送Command和完整ACT Plane，检查raw、INT8、物理lane位置、输出延迟、寄存器保持和weight Hold复用。没有直接注入Psum或Requant输入。

## 矩阵场景

- w4_high：X[8,192]×W[192,8]，W4A16，OS1/WS8/AS1，选择Macro4～7。split=0x01、EN=0xf0、输出lane4～7，两批N4，权重地址0x80/0x81。首行raw/INT8相对接受沿为C8/C9。
- w2_high：X[8,192]×W[192,8]，W2A8，OS1/WS8/AS1，选择Macro6～7。split=0x07、EN=0xc0、输出lane12～15，两批N4，地址0x90/0x91。首行raw/INT8为C5/C6。
- n_tail：X[8,160]×W[160,6]，W4A16、Macro4～7、OS1/WS8/AS1，地址0xa0/0xa1。第二批只使用OC0和OC2，mask=0101；逻辑列4、5分别对应物理lane4、6。OC1/3无valid且INT8寄存器保持。OC2继续选择参数2，不能压缩成参数1。
- boundaries：X[12,160]×W[160,4]，W4A16、Macro4～7、OS1/WS12/AS1、地址0xb0。用前四行单位基权重得到可控点积，其余K权重为0；仍完整通过Macro乘法和归约路径。四项multiplier为[1,3,1,1]、shift为[-1,-2,0,0]、merged zp为[0,1,100,-100]。ACT_zp=11，输入补偿已合入这四项zp。

前三类各运行per-tensor weight与per-channel weight两个版本，边界场景运行定向per-channel Requant版本，共7个suite，比较400个raw和400个INT8矩阵元素。K尾部和N无效OC的权重均补零。

## Python golden与边界覆盖

gemm_edges_vectors.py独立计算矩阵点积、量化编码、逐列weight scale、multiplier/shift和合并zp。前三类采用per-tensor非对称ACT、对称weight和共用输出scale；per-channel weight逐列独立校准。边界场景使用定向参数，以保证命中舍入与饱和边界。

整数golden使用任意精度整数与Fraction，舍入为半整数远离零，先round、后加zp、最后clip。SV另用未打包的整数X/W复核点积，并独立核对权重位段和ACT Plane。

边界矩阵实际覆盖：正半整数5项、负半整数5项、低端越界2项、高端越界4项、精确-128两项、精确127两项。Python强制断言覆盖非零，metadata记录clip前值及覆盖；SV每个结果必须精确匹配。原始实数数学参考另存，W2量化误差不能用来放宽硬件整数比较。

## 文件职责

- tb_Cluster_GEMM_Edges.sv：单Cluster连接、最大数组边界和共享观察状态。
- include/cluster_gemm_edges_driver.svh：配置读取、矩阵点积/打包复核、真实SRAM预加载读回、WS驱动和固定OC参数映射。
- include/cluster_gemm_edges_scoreboard.svh：地址/ACT/phase/Context、输出位置、尾部mask、golden、1T延迟和保持。
- include/cluster_gemm_edges_regression.svh：N批次调度、排空和完整矩阵写出。
- data/gemm_edges/：各suite的矩阵、参数、地址布局、ACT、输入计划、golden、实际输出及SHA256。

## 运行

VCS 运行入口及各 case 的参数见 [vcs-rtl 使用说明](../vcs-rtl/README.md)。

make regression也包含全部7组。每个suite和N批次开始均打印英文时间戳及描述。

独立生成：

```text
python RTL/cluster/tb/py/gemm_edges_vectors.py OUTPUT_DIR --case w4_high
python RTL/cluster/tb/py/gemm_edges_vectors.py OUTPUT_DIR --case w2_high --per-tensor
```

--case支持w4_high、w2_high、n_tail、boundaries。默认per-channel weight；--per-tensor适用于前三类，边界case只支持定向per-channel版本。

VCS执行 `make run CASE=gemm_edge_n_tail_channel` 等七个gemm_edge_*预设，使用verilog_file_gemm_edges.f，自动生成数据及设置GEMM_DATA_DIR。`make gemm-regression`运行全部11个正向GEMM。数据配置决定精度、尺寸、组位置及模式。
