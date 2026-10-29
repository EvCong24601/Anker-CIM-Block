"""Run regular SRAM tests, conflict checks, and existing RTL regressions in a local snapshot."""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
from requant_vectors import write_vectors,write_channel_vectors
from gemm_os1_ws32_w8a16_vectors import generate as generate_gemm, verify_outputs as verify_gemm
from gemm_os2_as4_w8a16_vectors import generate as generate_as_gemm, verify_outputs as verify_as_gemm
from gemm_os1_ws1_as8_w8a16_vectors import generate as generate_as8_gemm, verify_outputs as verify_as8_gemm
from gemm_scenario_vectors import generate as generate_scenario_gemm, verify_outputs as verify_scenario_gemm, TOPS as GEMM_TOPS
import svfiles


def summarize_simulation(name, log, expected, returncode, negative=False):
    """Report an expected rejection as PASS, while rejecting unrelated failures."""
    fatal_messages = [m.strip() for m in re.findall(
        r'^\s*#?\s*\*\* Fatal:\s*(.+)$', log, re.MULTILINE)]
    if '** Error:' in log:
        raise ValueError('unexpected simulator error')
    if negative:
        # Do not accept a diagnostic mentioned in a banner or an unrelated Fatal.
        if fatal_messages != [expected]:
            raise ValueError(f'expected exactly one protocol rejection: {expected}')
        result = f'PASS {name}: caught expected {expected}'
    else:
        if returncode or fatal_messages or expected not in log:
            raise ValueError('missing success marker or unexpected simulation failure')
        marker = next(line.strip().removeprefix('# ').removeprefix('PASS ')
                      for line in log.splitlines() if expected in line)
        if marker.startswith(name+' '):
            marker = marker[len(name)+1:]
        result = f'PASS {name}: {marker}'
    if '[CASE_START] time=' not in log or 'description=' not in log:
        raise ValueError('missing timestamp/description at case start')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sim-dir', type=Path)
    parser.add_argument('--full', action='store_true', help='also run all Cluster suites and large-Context capacity checks')
    parser.add_argument('--gemm-only',action='store_true',help='run only the single-Cluster four-N4-tile W8A16 M32/K128/N16 WS GEMM')
    parser.add_argument('--gemm-as-only',action='store_true',help='run only W8A16 M32/K512/N16 OS2/AS4 and its Context-config negative checks')
    parser.add_argument('--gemm-as8-only',action='store_true',help='run OS1/WS1/AS8 GEMM, buffer gates and command switches')
    parser.add_argument('--gemm-scenarios-only',action='store_true',help='run W4/W2 high-group, N-tail and rounding/clipping end-to-end matrices')
    parser.add_argument('--context-stress', action='store_true',
                        help='also check OS1 WS/AS64 and OS2 WS/AS8 with Psum depth 16')
    parser.add_argument('--input-overlap', action='store_true',
                        help='also check same-packet ACT/address reception during internal issue')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[4]
    dest = (args.sim_dir or root.parent / 'cluster_tb_work/local_sim/sram_rw').resolve()
    if dest == root or root in dest.parents:
        parser.error('--sim-dir must be outside the Git checkout')
    dest.mkdir(parents=True, exist_ok=True)
    cluster_tb = root / 'RTL/cluster/tb'
    macro = root / 'RTL/macro'
    # Every registered target is compiled into one library. The vcs-rtl/verilog_file_*.f
    # lists are the only place a source file is registered, so a new TB cannot be
    # silently left out of this snapshot compile.
    sources = svfiles.compile_union(svfiles.targets())
    manifest = []
    for src in sources:
        shutil.copy2(src, dest / src.name)
        manifest.append(f'{hashlib.sha256(src.read_bytes()).hexdigest()}  {src.relative_to(root)}')
    # Include fragments retain their paths relative to the owning TB.
    # Copy and hash them too; otherwise the snapshot would use incomplete tests.
    for owner in (cluster_tb, macro / 'tb'):
        for src in sorted((owner / 'include').glob('*.svh')):
            target = dest / src.relative_to(owner)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, target)
            manifest.append(f'{hashlib.sha256(src.read_bytes()).hexdigest()}  {src.relative_to(root)}')
    (dest / 'sources.sha256').write_text('\n'.join(manifest)+'\n', encoding='utf-8')

    def command(argv, name):
        result = subprocess.run(argv, cwd=dest, capture_output=True, text=True, errors='replace')
        (dest / f'{name}.console.log').write_text(result.stdout+result.stderr, encoding='utf-8')
        if result.returncode:
            raise RuntimeError(f'{name} failed ({result.returncode}); see {dest / (name+".console.log")}')

    command(['vlib', 'work'], 'vlib')
    command(['vlog', '-sv', '-svinputport=var', '+incdir+.', '+define+SINGLE_MACRO_ASSERTIONS',
             *[s.name for s in sources]], 'compile')
    summary = []

    def simulate(name, top, options, expected, negative=False):
        if top=='tb_Cluster' and name.startswith('requant_'):
            options=['-gENABLE_REQUANT=1',*options]
        # Expected protocol failures intentionally stop before the TB success marker.
        result = subprocess.run(['vsim', '-c', '-onfinish', 'stop', f'work.{top}', *options,
                                 '-l', name+'.log', '-do',
                                 'onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0'],
                                cwd=dest, capture_output=True, text=True, errors='replace')
        (dest / (name+'.console.log')).write_text(result.stdout+result.stderr, encoding='utf-8')
        log = (dest / (name+'.log')).read_text(errors='replace')
        try:
            status = summarize_simulation(name, log, expected, result.returncode, negative)
        except ValueError as exc:
            raise RuntimeError(f'FAIL {name}: {exc}; see {dest / (name+".log")}') from exc
        if name.startswith('gate_equiv_') and 'PASS cluster_gate_equivalence cycles=' not in log:
            raise RuntimeError('missing complete Cluster gate comparison: '+name)
        summary.append(status)
        print(summary[-1], flush=True)

    if args.full or args.gemm_as8_only:
        for channel in (False, True):
            name='gemm_os1_ws1_as8_w8a16_'+('channel' if channel else 'tensor')
            data=dest/name
            generate_as8_gemm(data,per_channel=channel)
            options=['+GEMM_DATA_DIR='+data.as_posix()]
            if channel:
                options.append('+PER_CHANNEL_SCALE')
            simulate(name,'tb_Cluster_GEMM_OS1_WS1_AS8_W8A16',options,
                     'PASS gemm_os1_as8_w8a16 M=8 K=256 N=32')
            verify_as8_gemm(data)
        if args.gemm_as8_only:
            summary.append('PASS regression: suites=2 expected_rejections=0')
            (dest/'validation.log').write_text('\n'.join(summary)+'\n',encoding='utf-8')
            print(summary[-1],flush=True)
            return
    if args.full or args.gemm_scenarios_only:
        for case in GEMM_TOPS:
            for per_channel in ((True,) if case=='w4a16_round_clip' else (False,True)):
                ws = 12 if case == 'w4a16_round_clip' else 8
                name=f'gemm_os1_ws{ws}_as1_{case}_'+('channel' if per_channel else 'tensor')
                data=dest/name
                meta=generate_scenario_gemm(data,case,per_channel)
                print(f'GEMM scenario: {name} M={meta["M"]} K={meta["K"]} N={meta["N"]} coverage={meta["coverage"]}',flush=True)
                simulate(name,GEMM_TOPS[case],['+GEMM_DATA_DIR='+data.as_posix(),'+GEMM_CASE_NAME='+name],
                         'PASS gemm_'+case)
                verify_scenario_gemm(data)
        if args.gemm_scenarios_only:
            summary.append('PASS regression: suites=7 expected_rejections=0')
            (dest/'validation.log').write_text('\n'.join(summary)+'\n',encoding='utf-8')
            print(summary[-1],flush=True)
            return
    if args.full or args.gemm_as_only:
        data=dest/'gemm_as_data'
        meta=generate_as_gemm(data)
        print(f'AS GEMM parameters: multiplier={meta["multiplier"]} shift={meta["shift"]} act_zp={meta["act_zp"]} per-channel zp={meta["requant_zp"]}',flush=True)
        simulate('gemm_os2_ws1_as4_w8a16_tensor','tb_Cluster_GEMM_OS2_AS4_W8A16',['+GEMM_DATA_DIR='+data.as_posix()],
                 'PASS gemm_os2_as4_w8a16 M=32 K=512 N=16')
        verify_as_gemm(data)
        for name,options,message in (
            ('as_context_capacity',['-gZP_DEPTH=2'],'AS context zp depth exceeded'),
            ('as_context_capacity_default',['-gZP_DEPTH=1'],'AS context zp depth exceeded'),
            ('as_context_zp_reload',['+NEGATIVE_ZP_RELOAD'],'AS context zp changed across K Tiles'),
        ):
            data=dest/name
            per_channel = name == 'as_context_zp_reload'
            generate_as_gemm(data,per_channel=per_channel)
            if per_channel:
                options = ['+PER_CHANNEL_SCALE', *options]
            simulate(name,'tb_Cluster_GEMM_OS2_AS4_W8A16',options+['+GEMM_DATA_DIR='+data.as_posix()],
                     'CLUSTER_REQUANT_CONFIG: '+message,True)
        data=dest/'gemm_as_channel_data'
        generate_as_gemm(data,per_channel=True)
        simulate('gemm_os2_ws1_as4_w8a16_channel','tb_Cluster_GEMM_OS2_AS4_W8A16',
                 ['+PER_CHANNEL_SCALE','+GEMM_DATA_DIR='+data.as_posix()],
                 'PASS gemm_os2_as4_w8a16 M=32 K=512 N=16')
        verify_as_gemm(data)
        data=dest/'as_context_scale_reload';generate_as_gemm(data,per_channel=True)
        simulate('as_context_scale_reload','tb_Cluster_GEMM_OS2_AS4_W8A16',
                 ['+PER_CHANNEL_SCALE','+NEGATIVE_SCALE_RELOAD','+GEMM_DATA_DIR='+data.as_posix()],
                 'CLUSTER_REQUANT_CONFIG: AS context scale changed across K Tiles',True)
        data=dest/'as_context_tensor_scale_reload';generate_as_gemm(data)
        simulate('as_context_tensor_scale_reload','tb_Cluster_GEMM_OS2_AS4_W8A16',
                 ['+NEGATIVE_SCALE_RELOAD','+GEMM_DATA_DIR='+data.as_posix()],
                 'CLUSTER_REQUANT_CONFIG: AS context scale changed across K Tiles',True)
        if args.gemm_as_only:
            summary.append('PASS regression: suites=7 expected_rejections=5')
            (dest/'validation.log').write_text('\n'.join(summary)+'\n',encoding='utf-8')
            print(summary[-1],flush=True)
            return
    if args.full or args.gemm_only:
        data=dest/'gemm_data'
        meta=generate_gemm(data)
        print(f'GEMM parameters: multiplier={meta["multiplier"]} shift={meta["shift"]} act_zp={meta["act_zp"]} output_zp={meta["output_zp"]}',flush=True)
        simulate('gemm_os1_ws32_as1_w8a16_tensor','tb_Cluster_GEMM_OS1_WS32_W8A16',['+GEMM_DATA_DIR='+data.as_posix()],
                 'PASS gemm_os1_ws32_w8a16 M=32 K=128 N=16')
        verify_gemm(data)
        data=dest/'gemm_channel_data';generate_gemm(data,per_channel=True)
        simulate('gemm_os1_ws32_as1_w8a16_channel','tb_Cluster_GEMM_OS1_WS32_W8A16',
                 ['+PER_CHANNEL_SCALE','+GEMM_DATA_DIR='+data.as_posix()],
                 'PASS gemm_os1_ws32_w8a16 M=32 K=128 N=16')
        verify_gemm(data)
        if args.gemm_only:
            summary.append('PASS regression: suites=2 expected_rejections=0')
            (dest/'validation.log').write_text('\n'.join(summary)+'\n',encoding='utf-8')
            print(summary[-1],flush=True)
            return
    simulate('sram_response','tb_Cluster',['+SRAM_RESPONSE_TEST'],'PASS sram_response reads=32')
    simulate('sram_rw', 'tb_Cluster', ['+SRAM_RW_TEST'], 'PASS sram_rw')
    simulate('sram_write_compute_conflict', 'tb_Cluster', ['+SRAM_CONFLICT_WRITE_COMPUTE'],
             'CLUSTER_SRAM_PROTOCOL: regular access overlaps compute', True)
    simulate('sram_compute_conflict', 'tb_Cluster', ['+SRAM_CONFLICT_COMPUTE'],
             'CLUSTER_SRAM_PROTOCOL: regular access overlaps compute', True)
    for gate in (0, 1):
        simulate(f'macro_gate{gate}', 'tb_SingleMacro', [f'-gCLOCK_GATING={gate}'], 'PASS clock_gating=')
    negatives = {
        'precision': 'illegal precision/phase', 'phase': 'illegal precision/phase',
        'hold_invalid': 'reuse invalid hold', 'uninitialized': 'read uninitialized row',
        'masked_uninitialized': 'read uninitialized row',
        'masked_uninitialized_reuse': 'read uninitialized row',
        'hold_address': 'reuse address mismatch', 'hold_address_pending': 'reuse address mismatch',
        'unknown_write': 'unknown write input', 'unknown_activation': 'unknown compute input',
        'unknown_control': 'unknown compute input', 'read_write': 'simultaneous read/write',
        'write_busy': 'write before pipeline drain', 'hold_after_write': 'reuse invalid hold',
        'hold_after_reset': 'reuse invalid hold',
    }
    for case, message in negatives.items():
        simulate('macro_negative_'+case, 'tb_SingleMacro', ['+NEGATIVE='+case], 'SM_PROTOCOL: '+message, True)
    if args.full:
        vector_count=write_vectors(dest/'requant_vectors.txt')
        write_channel_vectors(dest/'requant_channel_vectors.txt')
        simulate('requant_unit', 'tb_ClusterRequant',
                 ['+REQUANT_VECTORS='+(dest/'requant_vectors.txt').as_posix(),
                  '+REQUANT_CHANNEL_VECTORS='+(dest/'requant_channel_vectors.txt').as_posix()],
                 f'PASS requant_unit cases={vector_count}')
        for scenario, message in (
            ('as17_capacity','AS count exceeds output depth'),
            ('mode','unknown configuration'),
            ('unknown','unknown configuration'),
            ('conv_group','Requant requires one aligned reduction group'),
            ('zp_group','Requant requires one aligned reduction group'),
        ):
            simulate('requant_negative_'+scenario,'tb_Cluster',
                     ['+REQUANT_NEGATIVE='+scenario], ('CLUSTER_CONTEXT_CAPACITY: ' if scenario=='as17_capacity' else 'CLUSTER_REQUANT_CONFIG: ')+message, True)
        simulate('requant_full_shift','tb_Cluster',
                 ['+CONTEXT_BUFFER_TEST','+FULL_SHIFT_TEST','-gCHECK_GATE_EQUIVALENCE=1'],
                 'PASS context_buffers cases=77')
        simulate('requant_empty_batch','tb_Cluster',
                 ['+EMPTY_BATCH_TEST','-gCHECK_GATE_EQUIVALENCE=1'], 'PASS empty_batch cases=7')
        data=dest/'requant_integration_data'
        data.mkdir(exist_ok=True)
        simulate('requant_integration','tb_Cluster',
                 ['+REQUANT_TEST','+DATA_DIR='+data.as_posix()], 'PASS requant_integration cases=168')
        data=dest/'requant_channel_data';data.mkdir(exist_ok=True)
        simulate('requant_channel','tb_Cluster',['+REQUANT_CHANNEL_TEST','+DATA_DIR='+data.as_posix()],
                 'PASS requant_channel cases=1536')
        data=dest/'requant_buffers_data';data.mkdir(exist_ok=True)
        simulate('requant_buffers','tb_Cluster',
                 ['+CONTEXT_BUFFER_TEST','+DATA_DIR='+data.as_posix()],
                 'PASS context_buffers cases=77')
        data=dest/'requant_a4_address_bypass_data';data.mkdir(exist_ok=True)
        simulate('requant_a4_address_bypass','tb_Cluster',
                 ['-gWGT_RADDR_BUFFER_DEPTH=1','+CONTEXT_BUFFER_TEST','+A4_ONLY','+DATA_DIR='+data.as_posix()],
                 'PASS context_buffers cases=22')
        data=dest/'requant_context_data';data.mkdir(exist_ok=True)
        simulate('requant_context','tb_Cluster',['+REQUANT_CONTEXT_TEST','+DATA_DIR='+data.as_posix()],
                 'PASS requant_context cases=4')
        data=dest/'requant_reset_data'
        data.mkdir(exist_ok=True)
        simulate('requant_reset','tb_Cluster',
                 ['+REQUANT_RESET_TEST','+DATA_DIR='+data.as_posix()], 'PASS requant_reset')
        data=dest/'requant_boundary_data'
        data.mkdir(exist_ok=True)
        simulate('requant_boundary','tb_Cluster',
                 ['+REQUANT_BOUNDARY_TEST','+DATA_DIR='+data.as_posix()], 'PASS requant_boundary')
        for field in range(3):
            simulate(f'zero_count_{field}', 'tb_Cluster', [f'+ZERO_COUNT={field}'],
                     'CLUSTER_COUNT_RANGE: counts must be 1..255', True)
        data = dest / 'os_count_limit_data'
        data.mkdir(exist_ok=True)
        simulate('os_count_limit', 'tb_Cluster',
                 ['+OS_COUNT_LIMIT_TEST', '+DATA_DIR='+data.as_posix()],
                 'PASS os_count_limit cases=12')
        simulate('cluster_default', 'tb_Cluster', [], 'PASS configurations=')
        simulate('reduce_tree', 'tb_ClusterReduceTree', [], 'PASS reduce_clock_gating cases=208')
        for name, option, marker in (
            ('oc_merge', '+OC_MERGE_TEST', 'PASS oc_merge_leftmost cases=288'),
            ('act_buffer', '+ACT_BUFFER_TEST', 'PASS act_buffer_capacity cases=280'),
            ('full_act', '+FULL_ACT_TEST', 'PASS full_act_4096 cases=12'),
            ('mixed_context', '+MIXED_CONTEXT_TEST', 'PASS mixed_context cases=24'),
        ):
            # Keep each suite's CSV artifacts separate from the default run.
            data = dest / (name+'_data')
            data.mkdir(exist_ok=True)
            simulate(name, 'tb_Cluster', [option, '+DATA_DIR='+data.as_posix()], marker)
    if args.full or args.input_overlap:
        data = dest / 'input_overlap_data'
        data.mkdir(exist_ok=True)
        simulate('input_overlap', 'tb_Cluster',
                 ['+INPUT_OVERLAP_TEST', '+DATA_DIR='+data.as_posix()],
                 'PASS input_overlap cases=168')
    if args.full or args.context_stress:
        data = dest / 'context_stress_data'
        data.mkdir(exist_ok=True)
        capacity_config = ['-gMAX_CONTEXTS=64', '-gOUTPUT_BUFFER_DEPTH=16']
        simulate('context_stress', 'tb_Cluster',
                 capacity_config + ['+CONTEXT_STRESS_TEST', '+DATA_DIR='+data.as_posix()],
                 'PASS context_stress cases=224')
        for precision in range(7):
            for sign in (0, 1):
                simulate(f'context_capacity_p{precision}_s{sign}', 'tb_Cluster',
                         capacity_config + ['+CONTEXT_CAPACITY_TEST',
                                            f'+CAPACITY_PRECISION={precision}', f'+CAPACITY_SIGN={sign}'],
                         'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', True)
        for precision in range(7):
            for sign in (0,1):
                for os in (1,2):
                    simulate(f'as17_p{precision}_s{sign}_os{os}','tb_Cluster',
                             ['+CONTEXT_CAPACITY_TEST','+CAPACITY_COUNT=17',f'+CAPACITY_OS={os}',
                              f'+CAPACITY_PRECISION={precision}',f'+CAPACITY_SIGN={sign}'],
                             'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth',True)
        for precision in range(7):
            for sign in (0,1):
                simulate(f'as64_p{precision}_s{sign}_os1','tb_Cluster',
                         ['+CONTEXT_CAPACITY_TEST','+CAPACITY_COUNT=64','+CAPACITY_OS=1',
                          f'+CAPACITY_PRECISION={precision}',f'+CAPACITY_SIGN={sign}'],
                         'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth',True)
        # The address array and completion metadata are independent resources.
        for resource, override, flag, message in (
            ('address', '-gWGT_RADDR_BUFFER_DEPTH=8', '+ADDRESS_CAPACITY_TEST',
             'weight address depth exceeded'),
            ('metadata', '-gMAX_CONTEXTS=8', '+METADATA_CAPACITY_TEST',
             'context metadata exceeded'),
        ):
            for sign in (0, 1):
                simulate(f'{resource}_capacity_s{sign}', 'tb_Cluster',
                         [override, '+CONTEXT_CAPACITY_TEST', flag,
                          '+CAPACITY_PRECISION=6', f'+CAPACITY_SIGN={sign}'],
                         'CLUSTER_CONTEXT_CAPACITY: '+message, True)
    if args.full:
        for label,flag,quant,marker in [('default', '', False, 'PASS configurations='), ('requant_buffers', 'CONTEXT_BUFFER_TEST', True, 'PASS context_buffers cases=77'), ('requant_channel', 'REQUANT_CHANNEL_TEST', True, 'PASS requant_channel cases=1536'), ('context_stress', 'CONTEXT_STRESS_TEST', False, 'PASS context_stress cases=224'), ('input_overlap', 'INPUT_OVERLAP_TEST', False, 'PASS input_overlap cases=168'), ('sram', 'SRAM_RW_TEST', False, 'PASS sram_rw'), ('requant_reset', 'REQUANT_RESET_TEST', True, 'PASS requant_reset'), ('requant_boundary', 'REQUANT_BOUNDARY_TEST', True, 'PASS requant_boundary')]:
            name='gate_equiv_'+label;data=dest/(name+'_data');data.mkdir(exist_ok=True)
            options=['-gCHECK_GATE_EQUIVALENCE=1',f'-gENABLE_REQUANT={int(quant)}','+DATA_DIR='+data.as_posix()]
            if flag:options.append('+'+flag)
            simulate(name,'tb_Cluster',options,marker)
    if args.full:
        simulate('gate_equiv_sram_response','tb_Cluster',['-gCHECK_GATE_EQUIVALENCE=1','+SRAM_RESPONSE_TEST'],'PASS sram_response reads=32')
    suite_count = len(summary)
    expected_rejections = sum(': caught expected ' in line for line in summary)
    summary.append(f'PASS regression: suites={suite_count} expected_rejections={expected_rejections}')
    print(summary[-1], flush=True)
    (dest / 'validation.log').write_text('\n'.join(summary)+'\n', encoding='utf-8')
    print(f'Logs and source hashes: {dest}')


if __name__ == '__main__':
    main()
