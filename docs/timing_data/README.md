# 当前流水图的实测数据

来自当前 RTL 的 tb_ClusterChannels +TIMING_FIGURE 定向仿真，CSA 使用数学 golden；其余 LUT、CSA/结果寄存器、CPA、配置及 ICG 保持真实 RTL。5个任务、72个有效lane输出通过独立点积与采样沿检查；不构成固定工艺门连接或STA验证。

channel_events.csv 记录上升沿采样前的 valid/ready、issue 和本沿采样的 psum_valid_hex。channel_cycles.csv 的 last_output 是下游采样沿，不是沿后发布沿。TMP最终写入及valid发布比采样早一沿。

源码版本及逐文件SHA256见 provenance.json。复现命令见上级 Testbench_Guide.md；图由 `python docs/generate_pipeline_figures.py` 生成SVG，再用SVG渲染器同步PNG。此数据不是任意输入驱动的固定绝对周期模板。
