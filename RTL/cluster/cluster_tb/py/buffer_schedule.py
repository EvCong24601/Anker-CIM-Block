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


def operation(p, counts, k, c, ph):
    os, ws, ac = counts
    last = ph == ABITS[p] // 4 - 1
    fusion = ph > 0
    done = last and k == os - 1
    shift = 4 * ph
    t = f'T[{c if ac > 1 else 0}]'
    ps = f'P[{c}]'
    part = f'{t} + (R << {shift})' if fusion else 'R'
    op = 'fusion' if fusion else 'seed'
    ps_write = False
    tmp_write = False
    serial = False
    if os == 1:
        desc = ('fusion: ' + part) if fusion else '填充: R'
        tmp_write = ABITS[p] > 4
        dest = t if tmp_write else '直接输出'
        if done and tmp_write:
            dest += '；输出'
    elif ac > 1:
        ps_write = True
        dest = ps + ('；输出' if done else '')
        if ph > 0:
            desc = f'fusion: {ps} + (R << {shift})'
        elif k > 0:
            op = 'acc'
            desc = f'acc: {ps} + R'
        else:
            desc = '初次填充: R'
    else:
        tmp_write = ABITS[p] > 4
        dest = t if tmp_write else ''
        desc = ('fusion: ' + part) if fusion else '填充: R'
        if last:
            ps_write = True
            dest = (t + '；' if tmp_write else '') + ps + ('；输出' if done else '')
            if k > 0:
                op = 'fusion+acc' if fusion else 'acc'
                serial = fusion
                desc = (f'fusion: {part} → F；acc: {ps} + F' if fusion
                        else f'acc: {ps} + R')
            elif fusion:
                desc += '；融合值填充 Psum'
            else:
                desc = '初次填充: R'
    return dict(operation=op, description=desc, destination=dest,
                fusion=int(fusion), acc=int(op in ('acc', 'fusion+acc')),
                psum_write=int(ps_write), tmp_write=int(tmp_write),
                done=int(done), serial=int(serial))


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
    for q, (k, c, ph) in enumerate(sequence(p, counts)):
        row = operation(p, counts, k, c, ph)
        row.update(issue=q, tmp_capture=q + STANDARD_DELAY[p] - 1,
                   compute=q + STANDARD_DELAY[p], tile=k, context=c, phase=ph,
                   data=f'Tile{k} Ctx{c} A{ph}')
        yield row


def validate_trace(path):
    rows = list(csv.DictReader(Path(path).open()))
    expected = {(case, p, s, k, c, ph): (q + STANDARD_DELAY[p], operation(p, counts, k, c, ph))
                for case, counts in enumerate(COUNTS, 1) for p in range(7) for s in range(2)
                for q, (k, c, ph) in enumerate(sequence(p, counts))}
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
        assert result == value
    assert seen == expected.keys(), (len(seen), len(expected))
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
    manifest = list(csv.DictReader(args.manifest.open()))
    fields = ['config', 'precision', 'signed_en', 'split', 'en', 'oc', 'case', 'os', 'ws', 'as',
              'group', 'lane_mask', 'issue_cycle', 'tmp_capture', 'compute_cycle',
              'tile', 'context', 'phase', 'weight_address', 'operation', 'description',
              'destination', 'fusion', 'acc', 'psum_write', 'tmp_write', 'done', 'serial',
              'psum_depth_open_hex', 'icg_enable_cycle']
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
                    for q, (k, c, ph) in enumerate(sequence(p, counts)):
                        r = operation(p, counts, k, c, ph)
                        r.update(config=config, precision=p, signed_en=cfg['signed_en'],
                                 split=f'{split:02x}', en=f'{en:02x}', oc=f'{oc:08x}',
                                 case=case, os=os, ws=ws, **{'as': ac}, group=g, lane_mask=f'{mask:08x}',
                                 issue_cycle=q, tmp_capture=q+d-1, compute_cycle=q+d,
                                 tile=k, context=c, phase=ph,
                                 weight_address=f"8'h{0x20+16*k+(c if ac>1 else 0):02x}",
                                 psum_depth_open_hex=f'{((1 << max(ws,ac))-1) if os>1 else 0:x}',
                                 icg_enable_cycle=q+d-1)
                        writer.writerow(r)
                        count += 1
    text = ['Cluster tmp / bit-fusion / Psum acc 逐拍操作清单',
            'R=tmp_result 中当前归约结果；T[d]=tmp-buffer 融合状态；P[d]=Psum buffer。',
            '每个并行 channel=4*group+OC；OC 不串行。signed/unsigned 时序相同。',
            'C0 为首输入；tmp 在 C(q+D-1) 捕获，运算写回在 C(q+D)，ICG enable 提前一拍。',
            '标准 W2/W4/W8 的 D=3/4/5T。无停顿、无 requant；WS 串联路径需 STA。',
            'os=1 不写 Psum。AS 的 os>1：T0/A0 填充；后续 Tile A0 做 acc；其他 phase 做 fusion。',
            'n=as_cnt，P=A位宽/4：同 Context slice 间隔 n，Tile 间隔 n*P（不是 n*os_cnt）。',
            'Psum 高地址深度 d>=max(ws,as) 整批关闭；os=1 全部关闭。', '']
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
