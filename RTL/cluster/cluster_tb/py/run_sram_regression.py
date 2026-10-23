"""Run regular SRAM tests, conflict checks, and existing RTL regressions in a local snapshot."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sim-dir', type=Path)
    parser.add_argument('--full', action='store_true', help='also run default Cluster and reduction regressions')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[4]
    dest = (args.sim_dir or root.parent / 'cluster_tb_work/local_sim/sram_rw').resolve()
    if dest == root or root in dest.parents:
        parser.error('--sim-dir must be outside the Git checkout')
    dest.mkdir(parents=True, exist_ok=True)
    macro = root / 'RTL/macro'
    cluster = root / 'RTL/cluster/cluster_tb/sv_code'
    sources = [macro / 'rtl' / name for name in (
        'single_macro_pkg.sv', 'MacroClockGate.sv', 'MacroWeightSRAM.sv',
        'MacroMul2x4.sv', 'MacroSliceFusion.sv', 'SingleMacro.sv')]
    sources += [cluster / name for name in ('cluster_tb_pkg.sv', 'ClusterReduceTree.sv',
                'cluster_dut_adapter.sv', 'tb_Cluster.sv', 'tb_ClusterReduceTree.sv')]
    sources += [macro / 'tb/tb_SingleMacro.sv']
    manifest = []
    for src in sources:
        shutil.copy2(src, dest / src.name)
        manifest.append(f'{hashlib.sha256(src.read_bytes()).hexdigest()}  {src.relative_to(root)}')
    # Include fragments retain their paths relative to the owning TB.
    # Copy and hash them too; otherwise the snapshot would use incomplete tests.
    for owner in (cluster, macro / 'tb'):
        for src in sorted(owner.rglob('*.svh')):
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
        # Expected protocol failures intentionally stop before the TB success marker.
        result = subprocess.run(['vsim', '-c', '-onfinish', 'stop', f'work.{top}', *options,
                                 '-l', name+'.log', '-do',
                                 'onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0'],
                                cwd=dest, capture_output=True, text=True, errors='replace')
        (dest / (name+'.console.log')).write_text(result.stdout+result.stderr, encoding='utf-8')
        log = (dest / (name+'.log')).read_text(errors='replace')
        if expected not in log or '** Error:' in log or (not negative and ('** Fatal:' in log or result.returncode)):
            raise RuntimeError(f'{name} failed; see {dest / (name+".log")}')
        if '[CASE_START] time=' not in log or 'description=' not in log:
            raise RuntimeError(f'{name}: missing timestamp/description at case start')
        marker = next(line.strip() for line in log.splitlines() if expected in line)
        summary.append(f'{name}: {marker}')
        print(summary[-1], flush=True)

    simulate('sram_rw', 'tb_Cluster', ['+SRAM_RW_TEST'], 'PASS sram_rw')
    simulate('sram_preload_conflict', 'tb_Cluster', ['+SRAM_CONFLICT_PRELOAD'],
             'CLUSTER_SRAM_PROTOCOL: regular access overlaps preload', True)
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
    (dest / 'validation.log').write_text('\n'.join(summary)+'\n', encoding='utf-8')
    print(f'Logs and source hashes: {dest}')


if __name__ == '__main__':
    main()
