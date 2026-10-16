"""Independently validate a simulation-produced split manifest (stdlib only)."""
import csv
import sys
from pathlib import Path


def partitions(mask, node=0, start=0, size=8):
    if size == 1 or not (mask & (1 << node)):
        return [list(range(start, start + size))], 0
    left, lbits = partitions(mask, 2 * node + 1, start, size // 2)
    right, rbits = partitions(mask, 2 * node + 2, start + size // 2, size // 2)
    return left + right, lbits | rbits | (1 << node)


def main(path):
    rows = list(csv.DictReader(Path(path).open(encoding='utf-8')))
    assert rows, 'Empty manifest'
    en = int(rows[0]['en_mask_hex'], 16)
    oc = int(rows[0]['oc_mask_hex'], 16)
    wb = [2, 2, 4, 4, 4, 8, 8]
    expected = set()
    for p in range(7):
        for mask in range(128):
            groups, visited = partitions(mask)
            if visited != mask:
                continue
            if any(sum(bool(en & (1 << m)) for m in g) * (256 // wb[p]) >= 256
                   for g in groups):
                continue
            expected.update((p, s, mask) for s in range(2))
    actual = set()
    for row in rows:
        p, s = int(row['precision']), int(row['signed_en'])
        mask = int(row['split_mask_hex'], 16)
        assert int(row['en_mask_hex'], 16) == en
        assert int(row['oc_mask_hex'], 16) == oc
        key = p, s, mask
        assert key not in actual, f'Duplicate {key}'
        actual.add(key)
        groups, visited = partitions(mask)
        assert visited == mask
        k = [sum(bool(en & (1 << m)) for m in g) * (256 // wb[p]) for g in groups]
        assert [int(row[f'group{g}_K']) for g in range(8)] == k + [0] * (8-len(k))
        slots = int(row['slots_hex'], 16)
        for g in groups:
            active = [m for m in g if en & (1 << m)]
            selected = [(slots >> (3 * m)) & 7 for m in active]
            assert len(set(selected)) == len(selected)
            assert all(x < wb[p] for x in selected)
    assert actual == expected, f'Missing={expected-actual}, extra={actual-expected}'
    print(f'PASS independent enumeration: {len(actual)} configurations, EN={en:02x}, OC={oc:08x}')


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'split_cases.csv')
