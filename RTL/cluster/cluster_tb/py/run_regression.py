"""Run ModelSim, fail on diagnostics even if vsim returns exit status zero."""
import argparse
from pathlib import Path
import subprocess
import sys
import shutil
import json
import hashlib


def run(args):
    subprocess.run(args, cwd=ROOT, check=True)


PY_DIR = Path(__file__).resolve().parent
ROOT = PY_DIR.parent
SV_DIR = ROOT / 'sv_code'
DATA_DIR = ROOT / 'data'
LOG_DIR = ROOT / 'log'


def compile_sources(macro_override=None):
    candidates = [Path(macro_override)] if macro_override else [ROOT.parents[1] / 'macro' / 'rtl']
    macro_files = ('single_macro_pkg.sv', 'MacroClockGate.sv', 'MacroWeightSRAM.sv',
                   'MacroMul2x4.sv', 'MacroSliceFusion.sv', 'SingleMacro.sv')
    macro = next((p.resolve() for p in candidates if all((p / n).is_file() for n in macro_files)), None)
    if macro is None:
        raise RuntimeError('Cannot locate Macro RTL; specify --macro-rtl PATH')
    # Absolute source paths allow invoking this script from any directory.
    return [str(macro / n) for n in macro_files] + [str(SV_DIR / n) for n in (
        'cluster_tb_pkg.sv', 'ClusterReduceTree.sv', 'cluster_dut_adapter.sv',
        'tb_Cluster.sv', 'tb_ClusterReduceTree.sv', 'latency_audit.sv',
    )]


def main():
    global ROOT, SV_DIR, DATA_DIR, LOG_DIR, PY_DIR
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--os', type=int, default=1)
    parser.add_argument('--depth', '--psum-depth', dest='depth', type=int, default=16,
                        help='OUTPUT_BUFFER_DEPTH: Context entries per OC, 2..16 for this regression')
    parser.add_argument('--patterns', type=int, default=6)
    parser.add_argument('--en', default='ff', help='hex Macro enable mask')
    parser.add_argument('--oc', default='ffffffff', help='hex OC enable mask')
    parser.add_argument('--seed', default='19e2a407', help='hex xorshift seed')
    parser.add_argument('--log', default='regression.log')
    parser.add_argument('--macro-rtl', help='optional directory containing SingleMacro RTL')
    parser.add_argument('--latency-audit', action='store_true',
                        help='capture/check 140 no-stall Context latencies')
    parser.add_argument('--gate-unit', action='store_true',
                        help='also run the 208-case reduction clock-gating unit test')
    parser.add_argument('--mixed-context', action='store_true',
                        help='also run 24 mixed-endpoint WS/AS Context cases')
    parser.add_argument('--full-act', action='store_true',
                        help='also run 12 W8A16 full-4096-bit/K256 ACT cases')
    parser.add_argument('--sim-dir', type=Path,
                        help='local snapshot directory outside the Git checkout')
    args = parser.parse_args()
    if args.depth < 2 or args.depth > 16:
        parser.error('--depth must be 2..16 for the multi-Context regression (adapter permits 1)')
    source_root = ROOT
    source_files = compile_sources(args.macro_rtl)
    checkout = ROOT.parents[2]
    snapshot = (args.sim_dir or checkout.parent / 'cluster_tb_work' / 'local_sim' / Path(args.log).stem).resolve()
    if snapshot == checkout or checkout in snapshot.parents:
        parser.error('--sim-dir must be outside the Git checkout')
    snapshot.mkdir(parents=True, exist_ok=True)
    (snapshot / 'sv_code').mkdir(exist_ok=True)
    (snapshot / 'py').mkdir(exist_ok=True)
    sources = []
    manifest = {}
    for name in source_files:
        src = Path(name)
        target = snapshot / 'sv_code' / src.name
        shutil.copy2(src, target)
        sources.append(str(target))
        manifest[str(src)] = hashlib.sha256(src.read_bytes()).hexdigest()
    for src in PY_DIR.glob('*.py'):
        shutil.copy2(src, snapshot / 'py' / src.name)
        manifest[str(src)] = hashlib.sha256(src.read_bytes()).hexdigest()
    (snapshot / 'source_manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    ROOT, SV_DIR, PY_DIR = snapshot, snapshot / 'sv_code', snapshot / 'py'
    DATA_DIR, LOG_DIR = snapshot / 'data', snapshot / 'log'
    print(f'Local simulation snapshot: {snapshot}', flush=True)
    DATA_DIR.mkdir(exist_ok=True)
    LOG_DIR.mkdir(exist_ok=True)
    log_path = Path(args.log)
    if not log_path.is_absolute(): log_path = LOG_DIR / log_path
    log_path.parent.mkdir(parents=True, exist_ok=True)
    if not (ROOT / 'work').exists():
        run(['vlib', 'work'])
    run(['vlog', '-sv', '-svinputport=var',
         '+define+SINGLE_MACRO_ASSERTIONS', *sources])
    if args.gate_unit:
        gate_log = log_path.with_name(log_path.stem + '_reduce_gate.log')
        run(['vsim', '-c', '-onfinish', 'stop', 'work.tb_ClusterReduceTree',
             '-l', str(gate_log), '-do', 'run -all; quit -code 0'])
        gate_text = gate_log.read_text(errors='replace')
        if ('PASS reduce_clock_gating cases=208' not in gate_text or
                '** Fatal:' in gate_text or '** Error:' in gate_text):
            raise RuntimeError(f'Reduction gating unit test failed; see {gate_log}')
    if args.mixed_context:
        mixed_log = log_path.with_name(log_path.stem + '_mixed_context.log')
        run(['vsim', '-c', '-onfinish', 'stop', 'work.tb_Cluster',
             f'-gOUTPUT_BUFFER_DEPTH={args.depth}', '+MIXED_CONTEXT_TEST',
             f'+DATA_DIR={DATA_DIR.as_posix()}', '-l', str(mixed_log),
             '-do', 'run -all; quit -code 0'])
        mixed_text = mixed_log.read_text(errors='replace')
        if ('PASS mixed_context cases=24' not in mixed_text or
                '** Fatal:' in mixed_text or '** Error:' in mixed_text):
            raise RuntimeError(f'Mixed Context test failed; see {mixed_log}')
    if args.full_act:
        full_log = log_path.with_name(log_path.stem + '_full_act.log')
        run(['vsim', '-c', '-onfinish', 'stop', 'work.tb_Cluster',
             f'-gOUTPUT_BUFFER_DEPTH={args.depth}', '+FULL_ACT_TEST',
             f'+DATA_DIR={DATA_DIR.as_posix()}', '-l', str(full_log),
             '-do', 'run -all; quit -code 0'])
        full_text = full_log.read_text(errors='replace')
        if ('PASS full_act_4096 cases=12' not in full_text or
                '** Fatal:' in full_text or '** Error:' in full_text):
            raise RuntimeError(f'Full ACT test failed; see {full_log}')
    tops = ['work.tb_Cluster'] + (['work.latency_audit'] if args.latency_audit else [])
    run(['vsim', '-c', '-onfinish', 'stop', *tops,
         f'-gOS_TILES={args.os}',
         f'-gOUTPUT_BUFFER_DEPTH={args.depth}',
         f'-gPATTERNS={args.patterns}', f"-gEN_MASK=8'h{args.en}",
         f"-gOC_MASK=32'h{args.oc}", f"-gSEED=32'h{args.seed}",
         f'+DATA_DIR={DATA_DIR.as_posix()}', '-l', str(log_path), '-do',
         'onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0'])
    log = log_path.read_text(errors='replace')
    if 'PASS configurations=' not in log or '** Fatal:' in log or '** Error:' in log:
        raise RuntimeError(f'Simulation failed; see {args.log}')
    run([sys.executable, str(PY_DIR / 'verify_manifest.py'), str(DATA_DIR / 'split_cases.csv')])
    schedule_args = [sys.executable, str(PY_DIR / 'buffer_schedule.py'), '--psum-depth', str(args.depth),
                     '--trace', str(DATA_DIR / 'buffer_operations.csv')]
    run(schedule_args)
    if args.latency_audit:
        run([sys.executable, str(PY_DIR / 'audit_latency.py')])


if __name__ == '__main__':
    main()
