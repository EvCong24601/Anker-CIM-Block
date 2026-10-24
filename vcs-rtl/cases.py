"""VCS case catalogue, deterministic data preparation and diagnostic checking."""
from pathlib import Path
import argparse
import importlib
import re
import sys

HERE = Path(__file__).resolve().parent
PY = HERE.parent / 'RTL/cluster/tb/py'
sys.path.insert(0, str(PY))
CASES = {}


def add(name, tb, description, marker, args='', params='', generator='', channel=False, negative=False):
    CASES[name] = dict(tb=tb, description=description, marker=marker, args=args,
                       params=params, generator=generator, channel=channel, negative=negative)


add('cluster_default', 'cluster', 'Raw arithmetic and standard timing', 'PASS configurations=')
add('sram_rw', 'cluster', 'Regular SRAM read write and OC masks', 'PASS sram_rw', '+SRAM_RW_TEST')
for kind in ('preload', 'compute'):
    add('sram_'+kind+'_conflict', 'cluster', 'Reject regular SRAM overlap with '+kind,
        'CLUSTER_SRAM_PROTOCOL: regular access overlaps '+kind,
        '+SRAM_CONFLICT_'+kind.upper(), negative=True)
for gate in (0, 1):
    add('macro_gate'+str(gate), 'macro', 'SingleMacro clock gating '+str(gate), 'PASS clock_gating=',
        params=f'CLOCK_GATING={gate}')
for name, message in dict(precision='illegal precision/phase', phase='illegal precision/phase',
        hold_invalid='reuse invalid hold', uninitialized='read uninitialized row',
        masked_uninitialized='read uninitialized row', masked_uninitialized_reuse='read uninitialized row',
        hold_address='reuse address mismatch', hold_address_pending='reuse address mismatch',
        unknown_write='unknown write input', unknown_activation='unknown compute input',
        unknown_control='unknown compute input', read_write='simultaneous read/write',
        write_busy='write before pipeline drain', hold_after_write='reuse invalid hold',
        hold_after_reset='reuse invalid hold').items():
    add('macro_negative_'+name, 'macro', 'Reject '+name.replace('_', ' '),
        'SM_PROTOCOL: '+message, '+NEGATIVE='+name, negative=True)
add('requant_unit', 'requant', 'Integer quantization arithmetic and four OC mapping',
    'PASS requant_unit', generator='requant')
for name, message in dict(mode='per-channel scale requires conv_mode', shift_low='shift must be -31..31',
        shift_high='shift must be -31..31', unknown='unknown configuration',
        channel_shift='shift must be -31..31', conv_group='Requant requires one aligned reduction group',
        zp_group='Requant requires one aligned reduction group').items():
    add('requant_negative_'+name, 'cluster', 'Reject Requant '+name.replace('_', ' '),
        'CLUSTER_REQUANT_CONFIG: '+message, '+REQUANT_NEGATIVE='+name,
        params='ENABLE_REQUANT=1', negative=True)
for name, flag, marker in (
        ('requant_integration', 'REQUANT_TEST', 'PASS requant_integration cases=168'),
        ('requant_channel', 'REQUANT_CHANNEL_TEST', 'PASS requant_channel cases=1536'),
        ('requant_reset', 'REQUANT_RESET_TEST', 'PASS requant_reset'),
        ('requant_boundary', 'REQUANT_BOUNDARY_TEST', 'PASS requant_boundary'),
        ('os_count_limit', 'OS_COUNT_LIMIT_TEST', 'PASS os_count_limit cases=12'),
        ('oc_merge', 'OC_MERGE_TEST', 'PASS oc_merge_leftmost cases=288'),
        ('act_buffer', 'ACT_BUFFER_TEST', 'PASS act_buffer_capacity cases=280'),
        ('full_act', 'FULL_ACT_TEST', 'PASS full_act_4096 cases=12'),
        ('mixed_context', 'MIXED_CONTEXT_TEST', 'PASS mixed_context cases=24'),
        ('input_overlap', 'INPUT_OVERLAP_TEST', 'PASS input_overlap cases=168'),
        ('context_stress', 'CONTEXT_STRESS_TEST', 'PASS context_stress cases=224')):
    add(name, 'cluster', name.replace('_', ' '), marker, '+'+flag,
        params='ENABLE_REQUANT=1' if name.startswith('requant') else '')
add('reduce_tree', 'reduce', 'All reduction trees and clock gating', 'PASS reduce_clock_gating cases=208')
for field in range(3):
    add('zero_count_'+str(field), 'cluster', 'Reject zero count field '+str(field),
        'CLUSTER_COUNT_RANGE: counts must be 1..255', '+ZERO_COUNT='+str(field), negative=True)
for precision in range(7):
    for sign in (0, 1):
        add(f'context_capacity_p{precision}_s{sign}', 'cluster', 'Reject AS64 with OS2 and Psum depth16',
            'CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded',
            f'+CONTEXT_CAPACITY_TEST +CAPACITY_PRECISION={precision} +CAPACITY_SIGN={sign}', negative=True)
for resource, param, message in (('address', 'WGT_RADDR_BUFFER_DEPTH=32', 'weight address depth exceeded'),
                                  ('metadata', 'MAX_CONTEXTS=32', 'context metadata exceeded')):
    for sign in (0, 1):
        add(f'{resource}_capacity_s{sign}', 'cluster', 'Reject AS64 '+resource+' capacity',
            'CLUSTER_CONTEXT_CAPACITY: '+message,
            f'+CONTEXT_CAPACITY_TEST +{resource.upper()}_CAPACITY_TEST +CAPACITY_PRECISION=6 +CAPACITY_SIGN={sign}',
            params=param, negative=True)
for mode in ('tensor', 'channel'):
    add('gemm_ws32_'+mode, 'gemm', 'W8A16 M32 K128 N16 OS1 WS32 '+mode,
        'PASS cluster_gemm M=32 K=128 N=16', generator='ws32', channel=mode=='channel')
    add('gemm_as4_'+mode, 'gemm_as', 'W8A16 M32 K512 N16 OS2 AS4 '+mode,
        'PASS gemm_os2_as4 M=32 K=512 N=16', generator='as4', channel=mode=='channel')
for name, params, args, message, channel in (
        ('as_context_capacity', 'ZP_DEPTH=2', '', 'AS context zp depth exceeded', False),
        ('as_context_zp_reload', '', '+NEGATIVE_ZP_RELOAD', 'AS context zp changed across K Tiles', False),
        ('as_context_scale_reload', '', '+NEGATIVE_SCALE_RELOAD', 'AS context scale changed across K Tiles', True)):
    add(name, 'gemm_as', 'Reject '+name.replace('_', ' '), 'CLUSTER_REQUANT_CONFIG: '+message,
        args, params, 'as4', channel, True)
for edge in ('w4_high', 'w2_high', 'n_tail', 'boundaries'):
    for mode in (('channel',) if edge=='boundaries' else ('tensor', 'channel')):
        add('gemm_edge_'+edge+'_'+mode, 'gemm_edges', edge.replace('_', ' ')+' '+mode,
            'PASS gemm_edges', generator=edge, channel=mode=='channel')


def write_makefile():
    lines = ['# Generated by cases.py --write; edit the catalogue in cases.py.',
             'VALID_CASES := '+' '.join(CASES)]
    for name, c in CASES.items():
        lines.append(f'ifeq ($(CASE),{name})')
        for field in ('tb', 'description', 'args', 'params'):
            assignment='=' if field=='args' else ':='
            lines.append(f'CASE_{field.upper()} {assignment} {c[field]}'.rstrip())
        if c['channel'] and c['generator'] in ('ws32', 'as4'):
            lines.append('CASE_ARGS += +PER_CHANNEL_SCALE')
        if c['generator']=='requant':
            lines.append('CASE_ARGS += +REQUANT_VECTORS=$(abspath $(RUN_DIR))/requant_vectors.txt +REQUANT_CHANNEL_VECTORS=$(abspath $(RUN_DIR))/requant_channel_vectors.txt')
        elif c['generator']:
            lines.append('CASE_ARGS += +GEMM_DATA_DIR=$(abspath $(RUN_DIR))/data')
            if c['generator'] not in ('ws32','as4'):
                lines.append('CASE_ARGS += +EDGE_CASE_NAME=$(CASE)')
        lines.append('endif')
    (HERE/'cases.mk').write_text('\n'.join(lines)+'\n', encoding='utf-8')


def prepare(name, directory):
    directory.mkdir(parents=True, exist_ok=True)
    data=directory/'data';data.mkdir(exist_ok=True)
    c=CASES[name];gen=c['generator']
    if gen=='requant':
        mod=importlib.import_module('requant_vectors')
        mod.write_vectors(directory/'requant_vectors.txt')
        mod.write_channel_vectors(directory/'requant_channel_vectors.txt')
    elif gen in ('ws32', 'as4'):
        mod=importlib.import_module('gemm_vectors' if gen=='ws32' else 'gemm_os2_as4_vectors')
        mod.generate(data, per_channel=c['channel'])
    elif gen:
        importlib.import_module('gemm_edges_vectors').generate(data, gen, c['channel'])
    print(f'[CASE] name={name} description={c["description"]}')


def check(name, directory):
    c=CASES[name];log=(directory/'sim.log').read_text(encoding='utf-8', errors='replace')
    exit_status=(directory/'sim.exit').read_text().strip()
    if c['marker'] not in log:raise SystemExit('FAIL: missing expected marker: '+c['marker'])
    lines=log.splitlines()
    diagnostics=[i for i,line in enumerate(lines) if re.search(r'^\s*(?:#\s*)?(?:\*\*\s*)?(?:Fatal:|Fatal-|Error-|Error:|FATAL\b)',line,re.I)]
    # A negative suite succeeds only on its named protocol diagnostic. Other
    # simulator failures must never be mistaken for an expected rejection.
    if c['negative']:
        if exit_status not in ('0','1'):raise SystemExit('FAIL: abnormal simulator exit '+exit_status)
        windows=['\n'.join(lines[i:i+4]) for i in diagnostics]
        if len(windows)!=1 or c['marker'] not in windows[0]:
            raise SystemExit('FAIL: expected marker was not a fatal diagnostic')
        if not re.search(r'Fatal',lines[diagnostics[0]],re.I):raise SystemExit('FAIL: expected a fatal, not a simulator error')
    elif diagnostics:raise SystemExit('FAIL: unexpected diagnostics: '+'\n'.join(lines[i] for i in diagnostics))
    if not c['negative'] and exit_status!='0':
        raise SystemExit('FAIL: simulator returned nonzero status')
    if not c['negative']:
        if c['generator'] in ('ws32', 'as4'):
            importlib.import_module('gemm_vectors').verify_outputs(directory/'data')
        elif c['generator'] and c['generator']!='requant':
            importlib.import_module('gemm_edges_vectors').verify_outputs(directory/'data')
        if name=='cluster_default':
            import subprocess
            subprocess.run([sys.executable,str(PY/'verify_manifest.py'),str(directory/'data/split_cases.csv')],check=True)
    print('PASS VCS case '+name+(' expected rejection' if c['negative'] else ''))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--write', action='store_true');p.add_argument('--list', action='store_true')
    p.add_argument('--prepare', choices=CASES);p.add_argument('--check', choices=CASES)
    p.add_argument('--directory', type=Path)
    args=p.parse_args()
    if args.write:write_makefile()
    if args.list:
        for name,c in CASES.items():print(f'{name}: {c["description"]}'+(' [expected fatal]' if c['negative'] else ''))
    if args.prepare or args.check:
        if args.directory is None:p.error('--directory is required')
        (prepare if args.prepare else check)(args.prepare or args.check,args.directory.resolve())
