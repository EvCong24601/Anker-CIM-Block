"""W8A16 X[8,256] x W[256,32], OS1/WS1/AS8 integer golden."""
from gemm_os2_as4_w8a16_vectors import generate as generate_as, verify_outputs as verify_as
from pathlib import Path
import csv
import hashlib
import json


def generate(directory, per_channel=False):
    meta = generate_as(directory, seed=0x8125632, per_channel=per_channel,
                       rows=8, os_tiles=1, as_contexts=8, base_address=0xc0)
    out = Path(directory)
    # The AS8 driver rotates logical column groups between batches without reset.
    with (out/'input_schedule.csv').open(newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        fields, rows = reader.fieldnames, list(reader)
    for row in rows:
        if row['command_context']:
            logical = (int(row['command_context']) + int(row['row_m'])) % 8
            row['weight_address'] = f'0x{0xc0 + logical:02x}'
    with (out/'input_schedule.csv').open('w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fields)
        writer.writeheader()
        writer.writerows(rows)
    meta.update(context_rotation='logical_context=(context+row_m)%8',
                first_raw_per_row=30, first_quant_per_row=31,
                checks=['table_clocks', 'unwritten_context_hold', 'tensor_unused_channel_hold',
                        'accepted_command_overlap', 'invalid_command_poison', 'batch_context_reload'])
    (out/'gemm_metadata.json').write_text(json.dumps(meta, indent=2)+'\n', encoding='utf-8')
    (out/'vectors.sha256').write_text(''.join(
        f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n'
        for p in sorted(out.iterdir()) if p.is_file() and p.name != 'vectors.sha256'
        and not p.name.startswith('gemm_observed')), encoding='ascii')
    return meta


def verify_outputs(directory):
    verify_as(directory, expected_shape=(8, 256, 32))
