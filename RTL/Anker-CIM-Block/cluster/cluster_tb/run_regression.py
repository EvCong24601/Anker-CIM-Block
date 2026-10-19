"""Run ModelSim, fail on diagnostics even if vsim returns exit status zero."""
import argparse
from pathlib import Path
import subprocess
import sys


def run(args):
    subprocess.run(args, cwd=ROOT, check=True)


ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--depth', type=int, default=4,
                        help='signed32 entries per output channel (>=1)')
    parser.add_argument('--os', type=int, default=1)
    parser.add_argument('--patterns', type=int, default=6)
    parser.add_argument('--en', default='ff', help='hex Macro enable mask')
    parser.add_argument('--oc', default='ffffffff', help='hex OC enable mask')
    parser.add_argument('--seed', default='19e2a407', help='hex xorshift seed')
    parser.add_argument('--log', default='regression.log')
    args = parser.parse_args()
    if args.depth < 1:
        parser.error('--depth must be >=1')
    if not (ROOT / 'work').exists():
        run(['vlib', 'work'])
    run(['vlog', '-sv', '-svinputport=var',
         '+define+SINGLE_MACRO_ASSERTIONS', '-f', 'filelist.f'])
    run(['vsim', '-c', '-onfinish', 'stop', 'work.tb_Cluster',
         f'-gOUTPUT_BUFFER_DEPTH={args.depth}', f'-gOS_TILES={args.os}',
         f'-gPATTERNS={args.patterns}', f"-gEN_MASK=8'h{args.en}",
         f"-gOC_MASK=32'h{args.oc}", f"-gSEED=32'h{args.seed}",
         '-l', args.log, '-do',
         'onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0'])
    log = (ROOT / args.log).read_text(errors='replace')
    if 'PASS configurations=' not in log or '** Fatal:' in log or '** Error:' in log:
        raise RuntimeError(f'Simulation failed; see {args.log}')
    run([sys.executable, 'verify_manifest.py', 'split_cases.csv'])


if __name__ == '__main__':
    main()
