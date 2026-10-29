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
add('sram_write_compute_conflict', 'cluster', 'Reject regular SRAM write during active compute',
    'CLUSTER_SRAM_PROTOCOL: regular access overlaps compute', '+SRAM_CONFLICT_WRITE_COMPUTE', negative=True)
add('sram_compute_conflict', 'cluster', 'Reject regular SRAM read with compute Command',
    'CLUSTER_SRAM_PROTOCOL: regular access overlaps compute', '+SRAM_CONFLICT_COMPUTE', negative=True)
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
for name, message in dict(as17_capacity='AS count exceeds output depth', mode='per-channel scale requires conv_mode',
        unknown='unknown configuration',
        conv_group='Requant requires one aligned reduction group',
        zp_group='Requant requires one aligned reduction group').items():
    add('requant_negative_'+name, 'cluster', 'Reject Requant '+name.replace('_', ' '),
        ('CLUSTER_CONTEXT_CAPACITY: ' if name=='as17_capacity' else 'CLUSTER_REQUANT_CONFIG: ')+message, '+REQUANT_NEGATIVE='+name,
        params='ENABLE_REQUANT=1', negative=True)
for name, flag, marker in (
        ('requant_integration', 'REQUANT_TEST', 'PASS requant_integration cases=168'),
        ('requant_channel', 'REQUANT_CHANNEL_TEST', 'PASS requant_channel cases=1536'),
        ('requant_context', 'REQUANT_CONTEXT_TEST', 'PASS requant_context cases=4'),
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
add('requant_full_shift','cluster','Full INT10 AS Context parameters and OC gating',
    'PASS context_buffers cases=77','+CONTEXT_BUFFER_TEST +FULL_SHIFT_TEST',
    params='ENABLE_REQUANT=1 CHECK_GATE_EQUIVALENCE=1')
add('requant_empty_batch','cluster','Seven precisions empty batch to live batch clock hold',
    'PASS empty_batch cases=7','+EMPTY_BATCH_TEST',params='ENABLE_REQUANT=1 CHECK_GATE_EQUIVALENCE=1')
add('requant_buffers', 'cluster', 'Seven precisions AS16/AS8 fixed slots and A4 weight bypass',
    'PASS context_buffers cases=77', '+CONTEXT_BUFFER_TEST', params='ENABLE_REQUANT=1')
add('requant_a4_address_bypass','cluster','A4 AS16 with one weight address register',
    'PASS context_buffers cases=22','+CONTEXT_BUFFER_TEST +A4_ONLY',
    params='ENABLE_REQUANT=1 WGT_RADDR_BUFFER_DEPTH=1')
for precision in range(7):
    for sign in (0,1):
        for os in (1,2):
            add(f'as17_p{precision}_s{sign}_os{os}','cluster','Reject AS17 fixed-slot capacity',
                'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth',
                f'+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS={os} +CAPACITY_PRECISION={precision} +CAPACITY_SIGN={sign}',
                negative=True)
add('reduce_tree', 'reduce', 'All reduction trees and clock gating', 'PASS reduce_clock_gating cases=208')
for field in range(3):
    add('zero_count_'+str(field), 'cluster', 'Reject zero count field '+str(field),
        'CLUSTER_COUNT_RANGE: counts must be 1..255', '+ZERO_COUNT='+str(field), negative=True)
for precision in range(7):
    for sign in (0, 1):
        add(f'context_capacity_p{precision}_s{sign}', 'cluster', 'Reject AS64 with OS2 and Psum depth16',
            'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth',
            f'+CONTEXT_CAPACITY_TEST +CAPACITY_PRECISION={precision} +CAPACITY_SIGN={sign}', negative=True)
for resource, param, message in (('address', 'WGT_RADDR_BUFFER_DEPTH=8', 'weight address depth exceeded'),
                                  ('metadata', 'MAX_CONTEXTS=8', 'context metadata exceeded')):
    for sign in (0, 1):
        add(f'{resource}_capacity_s{sign}', 'cluster', 'Reject AS16 '+resource+' capacity',
            'CLUSTER_CONTEXT_CAPACITY: '+message,
            f'+CONTEXT_CAPACITY_TEST +{resource.upper()}_CAPACITY_TEST +CAPACITY_PRECISION=6 +CAPACITY_SIGN={sign}',
            params=param, negative=True)
for mode in ('tensor', 'channel'):
    add('gemm_os1_ws1_as8_w8a16_'+mode, 'gemm_os1_ws1_as8_w8a16',
        'W8A16 M8 K256 N32 OS1 WS1 AS8 buffer gating and command switches '+mode,
        'PASS gemm_os1_as8_w8a16 M=8 K=256 N=32', generator='as8', channel=mode=='channel')
    add('gemm_os1_ws32_as1_w8a16_'+mode, 'gemm_os1_ws32_w8a16', 'W8A16 M32 K128 N16 OS1 WS32 AS1 '+mode,
        'PASS gemm_os1_ws32_w8a16 M=32 K=128 N=16', generator='ws32', channel=mode=='channel')
    add('gemm_os2_ws1_as4_w8a16_'+mode, 'gemm_os2_as4_w8a16', 'W8A16 M32 K512 N16 OS2 WS1 AS4 '+mode,
        'PASS gemm_os2_as4_w8a16 M=32 K=512 N=16', generator='as4', channel=mode=='channel')
for name, params, args, message, channel in (
        ('as_context_capacity', 'ZP_DEPTH=2', '', 'AS context zp depth exceeded', False),
        ('as_context_capacity_default', 'ZP_DEPTH=1', '', 'AS context zp depth exceeded', False),
        ('as_context_zp_reload', '', '+NEGATIVE_ZP_RELOAD', 'AS context zp changed across K Tiles', True),
        ('as_context_scale_reload', '', '+NEGATIVE_SCALE_RELOAD', 'AS context scale changed across K Tiles', True),
        ('as_context_tensor_scale_reload', '', '+NEGATIVE_SCALE_RELOAD', 'AS context scale changed across K Tiles', False)):
    add(name, 'gemm_os2_as4_w8a16', 'Reject '+name.replace('_', ' '), 'CLUSTER_REQUANT_CONFIG: '+message,
        args, params, 'as4', channel, True)
for scenario in ('w4a16_high_group','w2a8_high_group','w4a16_n6_tail','w4a16_round_clip'):
    for mode in (('channel',) if scenario=='w4a16_round_clip' else ('tensor','channel')):
        ws = 12 if scenario == 'w4a16_round_clip' else 8
        add(f'gemm_os1_ws{ws}_as1_'+scenario+'_'+mode, 'gemm_'+scenario,
            f'OS1 WS{ws} AS1 '+scenario.replace('_',' ')+' '+mode,
            'PASS gemm_'+scenario, generator=scenario, channel=mode=='channel')

add('gate_equiv_default','cluster','Gated/ungated Cluster same-edge comparison: default','PASS configurations=','',params='CHECK_GATE_EQUIVALENCE=1 ENABLE_REQUANT=0')
add('gate_equiv_requant_buffers','cluster','Gated/ungated Cluster same-edge comparison: requant_buffers','PASS context_buffers cases=77','+CONTEXT_BUFFER_TEST',params='CHECK_GATE_EQUIVALENCE=1 ENABLE_REQUANT=1')
add('gate_equiv_requant_channel','cluster','Gated/ungated Cluster same-edge comparison: requant_channel','PASS requant_channel cases=1536','+REQUANT_CHANNEL_TEST',params='CHECK_GATE_EQUIVALENCE=1 ENABLE_REQUANT=1')
add('gate_equiv_context_stress','cluster','Gated/ungated Cluster same-edge comparison: context_stress','PASS context_stress cases=224','+CONTEXT_STRESS_TEST',params='CHECK_GATE_EQUIVALENCE=1 ENABLE_REQUANT=0')
add('gate_equiv_input_overlap','cluster','Gated/ungated Cluster same-edge comparison: input_overlap','PASS input_overlap cases=168','+INPUT_OVERLAP_TEST',params='CHECK_GATE_EQUIVALENCE=1 ENABLE_REQUANT=0')
add('gate_equiv_sram','cluster','Gated/ungated Cluster same-edge comparison: sram','PASS sram_rw','+SRAM_RW_TEST',params='CHECK_GATE_EQUIVALENCE=1 ENABLE_REQUANT=0')
add('gate_equiv_requant_reset','cluster','Gated/ungated Cluster same-edge comparison: requant_reset','PASS requant_reset','+REQUANT_RESET_TEST',params='CHECK_GATE_EQUIVALENCE=1 ENABLE_REQUANT=1')
add('gate_equiv_requant_boundary','cluster','Gated/ungated Cluster same-edge comparison: requant_boundary','PASS requant_boundary','+REQUANT_BOUNDARY_TEST',params='CHECK_GATE_EQUIVALENCE=1 ENABLE_REQUANT=1')
for precision in range(7):
    for sign in (0,1):
        add(f'as64_p{precision}_s{sign}_os1','cluster','Reject AS64 with OS1',
            'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth',
            f'+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=64 +CAPACITY_OS=1 +CAPACITY_PRECISION={precision} +CAPACITY_SIGN={sign}',negative=True)


add('sram_response','cluster','Synchronous read valid and sampled Macro response','PASS sram_response reads=32','+SRAM_RESPONSE_TEST')
add('gate_equiv_sram_response','cluster','Read response gated/ungated comparison','PASS sram_response reads=32','+SRAM_RESPONSE_TEST',params='CHECK_GATE_EQUIVALENCE=1')


def write_makefile():
    lines = ['# Generated by cases.py --write; edit the catalogue in cases.py.',
             'VALID_CASES := '+' '.join(CASES)]
    for name, c in CASES.items():
        lines.append(f'ifeq ($(CASE),{name})')
        for field in ('tb', 'description', 'args', 'params'):
            assignment='=' if field=='args' else ':='
            lines.append(f'CASE_{field.upper()} {assignment} {c[field]}'.rstrip())
        if c['channel'] and c['generator'] in ('ws32', 'as4', 'as8'):
            lines.append('CASE_ARGS += +PER_CHANNEL_SCALE')
        if c['generator']=='requant':
            lines.append('CASE_ARGS += +REQUANT_VECTORS=$(abspath $(RUN_DIR))/requant_vectors.txt +REQUANT_CHANNEL_VECTORS=$(abspath $(RUN_DIR))/requant_channel_vectors.txt')
        elif c['generator']:
            lines.append('CASE_ARGS += +GEMM_DATA_DIR=$(abspath $(RUN_DIR))/data')
            if c['generator'] not in ('ws32','as4','as8'):
                lines.append('CASE_ARGS += +GEMM_CASE_NAME=$(CASE)')
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
    elif gen in ('ws32', 'as4', 'as8'):
        module = {'ws32':'gemm_os1_ws32_w8a16_vectors', 'as4':'gemm_os2_as4_w8a16_vectors',
                  'as8':'gemm_os1_ws1_as8_w8a16_vectors'}[gen]
        mod=importlib.import_module(module)
        mod.generate(data, per_channel=c['channel'])
    elif gen:
        importlib.import_module('gemm_scenario_vectors').generate(data, gen, c['channel'])
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
    if name.startswith('gate_equiv_') and 'PASS cluster_gate_equivalence cycles=' not in log:
        raise SystemExit('FAIL: missing whole-Cluster gate equivalence marker')
    if c['generator']=='as8' and 'PASS as8_gate_switch active=' not in log:
        raise SystemExit('FAIL: missing AS8 gate and command-switch coverage')
    if not c['negative']:
        # Each generator owns the M/N its golden was built from, so the OS2/AS4 case
        # must not be checked by the WS32 verifier just because both are 32x16 today.
        verifier={'ws32':'gemm_os1_ws32_w8a16_vectors','as4':'gemm_os2_as4_w8a16_vectors',
                  'as8':'gemm_os1_ws1_as8_w8a16_vectors'}.get(c['generator'])
        if verifier:
            importlib.import_module(verifier).verify_outputs(directory/'data')
        elif c['generator'] and c['generator']!='requant':
            importlib.import_module('gemm_scenario_vectors').verify_outputs(directory/'data')
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
