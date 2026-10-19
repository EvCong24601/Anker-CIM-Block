# SingleMacro V0.2 交付说明

本目录为最小 RTL 集成交付包，包含 6 个 SystemVerilog 源文件、源文件清单及 [SPEC V0.2](SingleMacro_SPEC_v0.2.md)。顶层为 `SingleMacro`，端口定义见 SPEC 第 3、14 节。

## 文件与编译

按 `rtl/filelist.f` 的顺序编译：

1. `rtl/single_macro_pkg.sv`
2. `rtl/MacroClockGate.sv`
3. `rtl/MacroWeightSRAM.sv`
4. `rtl/MacroMul2x4.sv`
5. `rtl/MacroSliceFusion.sv`
6. `rtl/SingleMacro.sv`

文件清单中的路径相对于本目录。支持 filelist 的工具应从本目录运行，例如：

```text
iverilog -g2012 -DSYNTHESIS -s SingleMacro -o singlemacro.vvp -f rtl/filelist.f
```

以上为 RTL 编译/展开示例，不代表完成逻辑综合。SystemVerilog package 须先于引用它的模块编译。

## 集成约定

- 请求在上升沿 n 接受，四路 signed18 Phase Sum 在 n+1 更新后可见，Phase II=1；下游上升沿寄存器在 n+2 采样该结果。
- `reset` 高有效、异步置位；释放须由集成端同步并满足恢复/移除时序。SRAM 内容不复位，Hold-valid 复位。
- `cim_station=1` 读取 SRAM 并在完成边沿建立完整原始行 Hold；0 复用同地址 Hold，支持紧邻刷新后的复用。
- 零 OC mask 不发射。输出无 ready，Cluster 须提前预留接收位置。最后请求 n 后最早 n+2 写；最后写 w 后最早 w+1 发射刷新计算。
- `USE_CLOCK_GATING` 默认 1，使用功能 ICG 模型；置 0 使用普通时钟和寄存器使能。
- `MacroWeightSRAM` 是同步整行写、组合读的通用存储描述；物理 SRAM 替换须保证读访问和全部运算共用一拍。`MacroClockGate` 在 ASIC 流程中需适配工艺 ICG。

仿真时定义 `SINGLE_MACRO_ASSERTIONS` 可启用协议检查；定义 `SYNTHESIS` 排除仿真检查器。已完成门控开/关各两个 seed 的功能回归，9,048 笔结果及 13 类负向检查通过；尚未进行逻辑综合、门级仿真或 STA。

