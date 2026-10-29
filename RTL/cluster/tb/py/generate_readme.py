"""Generate the repository specification and 42 explicit input/operation tables."""
from pathlib import Path
from buffer_schedule import COUNTS, NAMES, ABITS, STANDARD_DELAY, sequence, standard_rows, groups, issue_cycle, external_rows

REPO = Path(__file__).resolve().parents[4]

BODY = r"""# CIM Cluster 输入与计算说明

八个 SingleMacro 组成一个 Cluster。当前包内ACT Plane、AS地址和量化参数接收与内部发射重叠；输入寄存后下一拍即可发射。正式输出为寄存INT8和逐lane valid，raw signed32仅供TB观察。批次配置及组合解码共享，Packet只存8bit变化地址；每OC的acc/bit-fusion复用一个组合加法器；三条归约路径的末Context完成位决定批次结束，逐lane完整性由独立TB检查。

## 源码与运行

- `RTL/macro/rtl/`：SingleMacro、同步读写SRAM、算术和功能ICG。
- `RTL/cluster/rtl/`：共享package、调度/存储、归约树和四通道Requant。
- `RTL/cluster/tb/`：Cluster、归约、量化和七个具体GEMM顶层；include拆分驱动、参考模型、检查器和case。
- `vcs-rtl/`：各顶层的编译列表、Makefile和用例目录；FSDB自动使用case说明后缀。

从 `vcs-rtl/` 执行 `make run CASE=cluster_default` 或 `make regression`。完整配置和用例说明见 [VCS入口](vcs-rtl/README.md)。

## 调度与缓存

所有多Context AS采用Tile → Slice → Context，包括OS1；WS/单Context采用Tile → Context → Slice。AS参数与地址不要求整包收齐，当前Context已收到即可计算。ACT bank为4096bit，后续Plane固定连续输入。

OUTPUT_PSUM_DEPTH默认16，统一控制Psum、权重地址表及Requant Context表深度；兼容参数可由容量专项单独覆盖。默认权重行地址表16×8bit；仅AS A8/A16使用深表，A4使用当前地址寄存器。Requant参数表默认16项，与OUTPUT_BUFFER_DEPTH一致，所有AS精度均使用固定槽位，不回收、不覆盖。所有精度cim_as_cnt≤16。

非AS关闭地址和量化参数深表，使用当前地址及批次参数。Per-tensor每Context仅使用第0组multiplier/shift并广播，另外三组关钟；ZP始终保留四项逐通道参数。参数c固定对应本地OC c，不按mask压缩。

Psum使用条件：`cim_os_cnt>1 || cim_as_cnt>1`。WS/单Context在tmp中融合Slice；所有AS多Context在Psum中保存各Context结果及融合历史；OS>1还累加K Tile。OS1 WS64合法，OS1 AS16合法，AS17/AS64拒绝。三个count均为8bit、1～255，WS/AS不能同时大于1。

## 时钟与结果

SRAM上升沿采样读写。同步读响应带sram_rd_valid，Macro编号随请求锁存；下一请求不改变当前响应。Macro在输入接受沿读权重，下一沿寄存计算结果，II=1。控制、SRAM访问及ACT分区时钟独立；权重由SRAM输出保持，行号/valid随访问更新；归约转发按节点/OC门控，tmp/Psum及INT8数据按对齐有效事件门控，valid保留清零尾沿。Context表采用整批门控。工艺ICG/SRAM映射及STA需由集成实现确认。

Requant使用一级组合算术及输出寄存器，INT8 valid比raw晚1T，没有输出反压。公式：`clip_INT8(round(raw × multiplier × 2^shift) + zp)`，半整数远离零，shift范围−512～511。merged ZP逐通道，scale支持per-tensor/per-channel。组编号由批次配置统一解码，四通道共享AS Context选择，各OC保留独立隔离和输出门控。

启用量化时每拍只允许一组、最多四个OC：W8八Macro归约，W4对齐四Macro组，W2对齐两Macro组。raw归约单测可关闭量化。中间tmp/Psum必须符合signed32范围；最终clip不修复历史回绕。

## 文档与测试

- [调度、逐拍时序及容量](docs/Cluster_Input_Overlap.md)
- [常规SRAM接口](docs/Cluster_Weight_SRAM_Interface.md)
- [Requant参数、门控及数值范围](docs/Cluster_Requant.md)
- [全部GEMM用例](docs/Cluster_GEMM.md)：13个正向矩阵、5个AS参数负向，包含OS1/WS1/AS8门控与Command切换检查。
- [TB结构和检查职责](docs/Testbench_Guide.md)

`context_stress`覆盖224个OS1/WS64、OS1/AS16、OS2/WS8、OS2/AS8 case。`requant_buffers`覆盖77个固定Context场景、2912个raw和2912个INT8比对，检查参数接收与发射重叠。A4旁路、AS17/64拒绝、异步复位、mask和门控由独立专项检查。所有case开始打印英文时间戳和描述。

完整验证条件与用例映射见[验证清单](docs/Cluster_Verification.md)。

## 附录 A 标准逐拍表

以下42组为raw调度/算术表，C0为首Command+A0接受沿；标准W2/W4/W8从内部发射到raw的D=3/4/5T。各表中的split/EN用于raw归约测试，不代表全部符合Requant单组限制。合法量化配置的输出比对应raw晚1T。
"""


def main():
    lines = [BODY.rstrip()]
    for case, counts in enumerate(COUNTS, 1):
        os, ws, ac = counts
        mode = 'AS' if ac > 1 else 'WS' if ws > 1 else '单 Context'
        lines += ['', f'### A{case} {mode} os={os} ws={ws} as={ac}',
                  f'每 Tile K=128；每 Context 总 K={os*128}。']
        for p, name in enumerate(NAMES):
            split, en = ('07','55') if p < 2 else ('01','33') if p < 5 else ('00','0F')
            lines += ['', f'#### precision={p} {name}',
                      f"split_mask=7'h{split}，EN=8'h{en}，OC_MASK=32'hFFFF_FFFF；D={STANDARD_DELAY[p]}T。",
                      '']
            lines += ['外部输入：', '', '| 外部周期 | i_cmd 与共享权重地址 | ACT |', '|---|---|---|']
            for e in external_rows(p,counts):
                cmd = f"Ctx{e['context']}，wgt_raddr=8'h{e['address']:02X}" if e['command'] else '—'
                act = f"A{e['phase']}(T{e['tile']})" if e['phase'] is not None else '—'
                lines.append(f"| C{e['cycle']} | {cmd} | {act} |")
            lines += ['', '内部发射与运算：', '', '| 内部发射周期 | wgt_raddr | ACT buffer 读出 | 运算写回 | 操作及目标 |', '|---|---|---|---|---|']
            seq = sequence(p, counts)
            last_addr = None
            for r in standard_rows(p, case):
                q,k,c,ph = (r[x] for x in ('issue','tile','context','phase'))
                address = 0x20+16*k+(c if ac>1 else 0)
                address_text = f"8'h{address:02X}" + ('（不变）' if address == last_addr else '')
                last_addr = address
                act = f'读 A{ph}(T{k})，Ctx{c}复用' if ac>1 else f'读 A{ph}(T{k},Ctx{c})'
                lines.append(f'| C{q} | {address_text} | {act} | C{r["compute"]} | {r["description"]} → {r["destination"]} |')
            out=[]
            for c in range(max(ws,ac)):
                q=max(issue_cycle(p,counts,k,cx,ph) for k,cx,ph in seq if cx==c)
                out.append(f'Ctx{c}：末内部发射 C{q}，raw 完成 C{q+STANDARD_DELAY[p]}')
            lines += ['', '；'.join(out)+'。']
    lines += ['', '## 附录 B 规范 split 编码', '',
              '以下按 bit6..bit0 给出26种规范编码，K 限制还需结合 precision、EN 和 OC：', '']
    masks=[]
    for mask in range(128):
        if not (mask&1) and mask: continue
        if not (mask&2) and (mask&0x18): continue
        if not (mask&4) and (mask&0x60): continue
        masks.append(mask)
    assert len(masks)==26
    lines.append('、'.join(f'`{x:07b}`' for x in masks))
    content='\n'.join(lines)+'\n'
    (REPO/'README.md').write_text(content,encoding='utf-8')
    print('Generated current-semantics README with 42 explicit input/operation tables')


if __name__ == '__main__':
    main()
