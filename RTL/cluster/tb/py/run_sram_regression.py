"""Compile and check raw-Psum Cluster regressions in an isolated source snapshot."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import importlib.util
import svfiles

ROOT=svfiles.ROOT
spec=importlib.util.spec_from_file_location('vcs_cases',ROOT/'vcs-rtl/cases.py')
catalog=importlib.util.module_from_spec(spec);spec.loader.exec_module(catalog)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sim-dir',type=Path)
    parser.add_argument('--case',action='append',choices=catalog.CASES)
    parser.add_argument('--full',action='store_true',help='run every raw-output and protocol case')
    args=parser.parse_args()
    dest=(args.sim_dir or ROOT.parent/'cluster_tb_work/local_sim/raw_psum').resolve()
    if dest==ROOT or ROOT in dest.parents:parser.error('--sim-dir must be outside the Git checkout')
    dest.mkdir(parents=True,exist_ok=True)
    sources=svfiles.compile_union(svfiles.targets())
    manifest={}
    for src in sources:
        shutil.copy2(src,dest/src.name);manifest[str(src)]=hashlib.sha256(src.read_bytes()).hexdigest()
    for owner in (ROOT/'RTL/cluster',ROOT/'RTL/macro'):
        for src in (owner/'tb/include').glob('*.svh'):
            (dest/'include').mkdir(exist_ok=True);shutil.copy2(src,dest/'include'/src.name)
            manifest[str(src)]=hashlib.sha256(src.read_bytes()).hexdigest()
        for src in list((owner/'rtl').glob('*_func.sv'))+list((owner/'tb').glob('*_func.sv')):
            shutil.copy2(src,dest/src.name);manifest[str(src)]=hashlib.sha256(src.read_bytes()).hexdigest()
    (dest/'sources.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    def command(argv,log):
        r=subprocess.run(argv,cwd=dest,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,errors='replace')
        log.write_text(r.stdout,encoding='utf-8');return r
    command(['vlib','work'],dest/'vlib.log')
    r=command(['vlog','-sv','-svinputport=var','+incdir+.','+define+SINGLE_MACRO_ASSERTIONS','-work','work',*[s.name for s in sources]],dest/'compile.log')
    if r.returncode:raise RuntimeError(f'Compile failed: {dest / "compile.log"}')
    names=args.case or (list(catalog.CASES) if args.full else [
        'cluster_default','reduce_tree','macro_gate1','input_overlap','os_count_limit','gate_equiv_default',
        *[n for n in catalog.CASES if n.startswith('gemm_')]])
    summaries=[]
    for name in names:
        case=catalog.CASES[name];run=dest/name;catalog.prepare(name,run)
        _,_,top=svfiles.compile_set(case['tb'])
        options=['-g'+p for p in case['params'].split()]
        options+=case['args'].split()+['+DATA_DIR='+str(run/'data')]
        if case['generator']:options+=['+GEMM_DATA_DIR='+str(run/'data')]
        if case['channel']:options+=['+PER_CHANNEL_SCALE']
        r=command(['vsim','-c','-quiet','-onfinish','stop','-lib','work',top,*options,'-do',
            'onbreak {quit -code 1}; onerror {quit -code 1}; run -all; quit -code 0'],run/'sim.log')
        (run/'sim.exit').write_text(str(r.returncode))
        catalog.check(name,run)
        line='PASS '+name;summaries.append(line);print(line,flush=True)
    (dest/'summary.log').write_text('\n'.join(summaries)+'\n')
    print(f'TOTAL PASS={len(summaries)} snapshot={dest}',flush=True)

if __name__=='__main__':main()