"""Check measured Context output times against the six configured schedules.

Standard-library-only checker: no external DOCX file or Python package needed.
"""
import csv
from pathlib import Path
from buffer_schedule import COUNTS, NAMES, STANDARD_DELAY, sequence, validate_trace

ROOT = Path(__file__).resolve().parents[1] / 'data'
LOG_DIR = ROOT.parent / 'log'


def main():
    expected = {}
    for case, counts in enumerate(COUNTS, 1):
        for p in range(7):
            for q, (k, c, ph) in enumerate(sequence(p, counts)):
                expected[case, p, c] = q, q + STANDARD_DELAY[p]
    rows = list(csv.DictReader((ROOT / 'latency_audit.csv').open()))
    seen = set()
    for r in rows:
        case, p, sign, ctx = (int(r[x]) for x in ('case', 'precision', 'signed_en', 'context'))
        key = case, p, sign, ctx
        assert key not in seen and sign in (0, 1), key
        seen.add(key)
        assert tuple(int(r[x]) for x in ('os', 'ws', 'as')) == COUNTS[case-1]
        measured = int(r['last_input']), int(r['raw_output'])
        assert measured == expected[case, p, ctx], (key, measured)
        assert int(r['delta']) == STANDARD_DELAY[p]
    complete = {(case, p, s, c) for case, p, c in expected for s in (0, 1)}
    assert seen == complete and len(rows) == 140, (len(seen), len(complete))
    events = validate_trace(ROOT / 'buffer_operations.csv')
    lines = ['PASS: 140 Context outputs and 480 buffer operations match the six schedules.',
             'Signed/unsigned timing identical; C0 is first input; no stalls or requant.',
             'From last input to raw: W2=3T, W4=4T, W8=5T.',
             f'Operation trace checked: {events} events.', '']
    for case, counts in enumerate(COUNTS, 1):
        lines.append(f'case {case}: os={counts[0]}, ws={counts[1]}, as={counts[2]}')
    lines.append('')
    for p, name in enumerate(NAMES):
        final = [expected[c, p, max(ct[1:])-1][1] for c, ct in enumerate(COUNTS, 1)]
        lines.append(f'precision={p} {name}: complete latency={STANDARD_DELAY[p]}T; final raw cycles={final}')
    report = '\n'.join(lines) + '\n'
    LOG_DIR.mkdir(exist_ok=True)
    (LOG_DIR / 'latency_audit_validation.log').write_text(report, encoding='utf-8')
    print(report)


if __name__ == '__main__':
    main()
