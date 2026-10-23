"""Enumerate buffer operations for the six agreed os/ws/as configurations.

Uses only Python's standard library. CSV expands every legal split/sign entry
in split_cases.csv; TXT lists the 42 standard precision/configuration examples.
All cycle numbers assume no input stalls and parallel OCs.
"""
import argparse
import csv
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / 'data'
COUNTS = ((1, 1, 1), (1, 1, 2), (1, 2, 1),
          (2, 1, 1), (2, 2, 1), (2, 1, 2))
NAMES = ('W2A4', 'W2A8', 'W4A4', 'W4A8', 'W4A16', 'W8A8', 'W8A16')
ABITS = (4, 8, 4, 8, 16, 8, 16)
STANDARD_DELAY = (3, 3, 4, 4, 4, 5, 5)


def sequence(p, counts):
    os, ws, ac = counts
    n = max(ws, ac)
    phases = ABITS[p] // 4
    if ac > 1:
        return [(k, c, ph) for k in range(os) for ph in range(phases) for c in range(n)]
    return [(k, c, ph) for k in range(os) for c in range(n) for ph in range(phases)]


def packet_start(p,counts,k,c):
    _,ws,ac=counts;P=ABITS[p]//4;R=max(ws,ac)
    return k*(1+R*P) if ac>1 else (k*R+c)*(P+1)


def issue_cycle(p,counts,k,c,ph):
    _,ws,ac=counts;P=ABITS[p]//4;R=max(ws,ac)
    return packet_start(p,counts,k,c)+1+(ph*R+c if ac>1 else ph)


def external_rows(p,counts):
    os,ws,ac=counts;P=ABITS[p]//4;R=max(ws,ac)
    for k in range(os):
        for packet_ctx in range(1 if ac>1 else R):
            start=packet_start(p,counts,k,packet_ctx)
            for q in range(max(P,R) if ac>1 else P):
                ctx=q if ac>1 else packet_ctx
                yield dict(cycle=start+q,tile=k,context=ctx if (q<R if ac>1 else q==0) else None,
                           command=(q<R if ac>1 else q==0),phase=q if q<P else None,
                           address=0x20+16*k+(ctx if ac>1 else 0))


def operation(p, counts, k, c, ph):
    os, ws, ac = counts
    last = ph == ABITS[p] // 4 - 1
    fusion = ph > 0
    acc = k > 0 and (ph == 0 if ac > 1 else last and os > 1)
    ps_write = (os > 1 or ABITS[p] > 4) if ac > 1 else (os > 1 and last)
    done = last and k == os - 1
    ps = f'P[{c}]'
    if ac > 1:
        desc = f'fusion: {ps} + (R_slice << {4*ph})' if fusion else f'acc: {ps} + R_slice' if acc else '填充: R_slice'
        dest = ps if ps_write else '直接输出'
    else:
        desc = f'tmp捕获前 fusion: tmp + (R_slice << {4*ph})' if fusion else 'tmp捕获: R_slice'
        if ps_write: desc += f'；下一拍 acc: {ps} + tmp' if acc else '；下一拍 tmp 填充 Psum'
        dest = 'tmp' + (f'；{ps}' if ps_write else '')
    if done and dest != '直接输出': dest += '；输出'
    return dict(operation='fusion_then_acc' if fusion and acc else 'fusion' if fusion else 'acc' if acc else 'seed',
                description=desc,destination=dest,fusion=int(fusion),acc=int(acc),
                psum_write=int(ps_write),tmp_write=1,done=int(done),serial=0)


def groups(split):
    out = []
    def walk(node, start, size):
        if size == 1 or not (split >> node) & 1:
            out.append(tuple(range(start, start + size)))
        else:
            walk(2 * node + 1, start, size // 2)
            walk(2 * node + 2, start + size // 2, size // 2)
    walk(0, 0, 8)
    return out


def standard_rows(p, case):
    counts = COUNTS[case - 1]
    for k,c,ph in sequence(p,counts):
        q=issue_cycle(p,counts,k,c,ph)
        row = operation(p, counts, k, c, ph)
        row.update(issue=q,external_command=packet_start(p,counts,k,c)+(c if counts[2]>1 else 0),
                   external_act=packet_start(p,counts,k,c)+ph,tmp_capture=q + STANDARD_DELAY[p] - 1,
                   compute=q + STANDARD_DELAY[p], tile=k, context=c, phase=ph,
                   data=f'Tile{k} Ctx{c} A{ph}')
        yield row


def validate_trace(path):
    rows = list(csv.DictReader(Path(path).open()))
    expected = {(case, p, s, k, c, ph): (issue_cycle(p,counts,k,c,ph) + STANDARD_DELAY[p], operation(p, counts, k, c, ph))
                for case, counts in enumerate(COUNTS, 1) for p in range(7) for s in range(2)
                for k,c,ph in sequence(p,counts)}
    seen = set()
    for row in rows:
        key = tuple(int(row[x]) for x in ('case', 'precision', 'signed_en', 'tile', 'context', 'phase'))
        assert key not in seen, key
        seen.add(key)
        cycle, ref = expected[key]
        assert int(row['compute_cycle']) == cycle, (key, row['compute_cycle'], cycle)
        assert row['operation'] == ref['operation'], (key, row['operation'], ref)
        assert int(row['done']) == ref['done']
        fa, fb, aa, ab, result = (int(row[x]) for x in ('fusion_a', 'fusion_b', 'acc_a', 'acc_b', 'result'))
        if not ref['fusion']: assert fa == fb == 0
        if not ref['acc']: assert aa == ab == 0
        value = aa + ab if ref['acc'] else fa + fb if ref['fusion'] else int(row['tmp'])
        stored = int(row['tmp_stored'])
        is_as = COUNTS[key[0]-1][2] > 1
        assert stored == (int(row['tmp']) if is_as or not ref['fusion'] else fa+fb)
        assert int(row['fusion_cycle']) == cycle-(0 if is_as else 1)
        assert result == value
    assert seen == expected.keys(), (len(seen), len(expected))
    return len(rows)


def validate_external_trace(path):
    rows=list(csv.DictReader(Path(path).open(encoding='utf-8')))
    expected={(case,p,sign,r['cycle']):r for case,counts in enumerate(COUNTS,1)
              for p in range(7) for sign in range(2) for r in external_rows(p,counts)}
    seen=set()
    for row in rows:
        key=tuple(int(row[x]) for x in ('case','precision','signed_en','input_cycle'))
        assert key not in seen,key
        seen.add(key);ref=expected[key]
        assert int(row['command'])==int(ref['command'])
        assert int(row['act_sample'])==int(ref['phase'] is not None)
        if ref['command']:
            assert int(row['context'])==ref['context']
            assert int(row['weight_address'],16)==ref['address']
        if ref['phase'] is not None:
            assert int(row['phase'])==ref['phase']
            assert len(row['act_hex'])==256
    assert seen==expected.keys(),(len(seen),len(expected))
    return len(rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--manifest', type=Path, default=ROOT / 'split_cases.csv')
    ap.add_argument('--psum-depth', type=int, default=16)
    ap.add_argument('--trace', type=Path, help='validate no-stall standard-case operation trace')
    args = ap.parse_args()
    ROOT.mkdir(exist_ok=True)
    if args.psum_depth < 2: ap.error('six examples need Psum capacity >=2')
    if args.trace:
        print('PASS buffer operation trace:', validate_trace(args.trace), 'events')
        print('PASS external input trace:',validate_external_trace(args.trace.parent/'external_inputs.csv'),'events')
    manifest = list(csv.DictReader(args.manifest.open()))
    fields = ['config', 'precision', 'signed_en', 'split', 'en', 'oc', 'case', 'os', 'ws', 'as',
              'group', 'lane_mask', 'issue_cycle', 'tmp_capture', 'compute_cycle',
              'tile', 'context', 'phase', 'weight_address', 'operation', 'description',
              'destination', 'fusion', 'acc', 'psum_write', 'tmp_write', 'done', 'serial',
              'psum_depth_open_hex', 'fusion_cycle', 'icg_enable_cycle', 'act_buffer_read', 'external_cmd_cycle', 'external_act_cycle', 'act_source']
    count = 0
    with (ROOT / 'buffer_cycle_cases.csv').open('w', newline='', encoding='utf-8-sig') as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for config, cfg in enumerate(manifest, 1):
            p = int(cfg['precision'])
            split, en, oc = (int(cfg[x], 16) for x in ('split_mask_hex', 'en_mask_hex', 'oc_mask_hex'))
            for case, counts in enumerate(COUNTS, 1):
                os, ws, ac = counts
                for g, members in enumerate(groups(split)):
                    mask = sum(1 << (4 * g + c) for c in range(4)
                               if any(en >> m & 1 and oc >> (4 * m + c) & 1 for m in members))
                    if not mask: continue
                    d = 3 if len(members) <= 2 else 4 if len(members) == 4 else 5
                    for k,c,ph in sequence(p,counts):
                        q=issue_cycle(p,counts,k,c,ph)
                        r = operation(p, counts, k, c, ph)
                        r.update(config=config, precision=p, signed_en=cfg['signed_en'],
                                 split=f'{split:02x}', en=f'{en:02x}', oc=f'{oc:08x}',
                                 case=case, os=os, ws=ws, **{'as': ac}, group=g, lane_mask=f'{mask:08x}',
                                 issue_cycle=q, tmp_capture=q+d-1, compute_cycle=q+d,
                                 tile=k, context=c, phase=ph,
                                 weight_address=f"8'h{0x20+16*k+(c if ac>1 else 0):02x}",
                                 psum_depth_open_hex=f'{((1 << max(ws,ac))-1) if (os>1 or (ac>1 and ABITS[p]>4)) else 0:x}',
                                 fusion_cycle=(q+d-(0 if ac>1 else 1)) if ph>0 else '',
                                 icg_enable_cycle=q+d-1,
                                 act_buffer_read=1,
                                 external_cmd_cycle=packet_start(p,counts,k,c)+(c if ac>1 else 0),
                                 external_act_cycle=packet_start(p,counts,k,c)+ph,
                                 act_source=f'A{ph}(T{k})' if ac>1 else f'A{ph}(T{k},Ctx{c})')
                        writer.writerow(r)
                        count += 1
    text = ['Cluster tmp / bit-fusion / Psum acc 逐拍操作清单',
            'R_slice=当前原始归约slice；R=max(ws_cnt,as_cnt)为Context数；每OC一个32-bit tmp，WS保存Tile融合前缀，AS保存当前R_slice；P[d]=32-bit Context Psum。',
            '每个并行 channel=4*group+OC；OC 不串行。signed/unsigned 时序相同。',
            '外部完整ACT输入P=A位宽/4个Plane；首slice随该包首命令，其余slice连续采样。AS各Context独立给地址命令，共用完整ACT。',
            'C0为首外部Command+A0；q为内部发射周期。当前Plane/地址寄存后一拍即可发射，与同包后续输入重叠；tmp在C(q+D-1)捕获，完成C(q+D)。',
            '标准 W2/W4/W8 的 D=3/4/5T。无停顿、无 requant；WS归约末级与fusion在tmp前的路径需STA。',
            'WS每Tile实际计算P*ws_cnt拍；ws_cnt仍为完整ACT/Context数，P=A位宽/4；无空拍时每Tile共(P+1)*ws_cnt拍。',
            'WS的os=1不写Psum；AS的A8/A16即使os=1也写P[ctx]保存fusion历史。首Tile/A0填充，后续Tile/A0 acc，高phase fusion。',
            'AS中n=as_cnt，P=A位宽/4：同Tile同Context的slice间隔n；相邻Tile同一slice间隔1+n*P，含下一包ACT/地址接收。',
            'Psum高地址深度d>=max(ws,as)整批关闭；每OC每拍只时钟一个Context entry。WS os=1及AS A4 os=1关闭Psum。', '']
    for p, name in enumerate(NAMES):
        for case, counts in enumerate(COUNTS, 1):
            text += [f'precision={p} {name} case={case} os/ws/as={"/".join(map(str,counts))}',
                     '输入 | tmp捕获 | 运算写回 | tmp中的数据 | 操作 | 回写']
            for r in standard_rows(p, case):
                text.append(f'C{r["issue"]} | C{r["tmp_capture"]} | C{r["compute"]} | '
                            f'{r["data"]} | {r["description"]} | {r["destination"]}')
            text.append('')
    (ROOT / 'buffer_cycle_cases.txt').write_text('\n'.join(text)+'\n', encoding='utf-8')
    print(f'Generated 42 standard examples; {len(manifest)*6} split/sign/config combinations; {count} group events')


if __name__ == '__main__':
    main()
