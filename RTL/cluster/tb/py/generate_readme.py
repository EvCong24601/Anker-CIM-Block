"""Generate the detailed timing document with 42 explicit input/operation tables."""
from pathlib import Path
from buffer_schedule import COUNTS, NAMES, ABITS, STANDARD_DELAY, sequence, standard_rows, groups, issue_cycle, external_rows

REPO = Path(__file__).resolve().parents[4]

BODY = r"""# Cluster 标准逐拍表

[返回项目入口](../README.md) · [调度与容量说明](Cluster_Input_Overlap.md)

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
    lines += ['', 'Requant的ZP参数均为生成端已round的signed INT32输出域补偿。per-tensor在CIM饱和INT8输出后仅由TB按channel扩位加ZP并再次clip，不再round；per-channel在RTL内先round、加ZP、再clip，TB不重复补偿。完整公式和参考代码转换见[Requant说明](Cluster_Requant.md)及[Block Spec第6.2节](CIM_Block_Spec.docx)。']
    content='\n'.join(lines)+'\n'
    (REPO/'docs/Cluster_Timing_Tables.md').write_text(content,encoding='utf-8')
    print('Generated docs/Cluster_Timing_Tables.md with 42 explicit input/operation tables')


if __name__ == '__main__':
    main()
