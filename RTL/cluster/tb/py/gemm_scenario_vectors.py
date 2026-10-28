"""End-to-end GEMM vectors for high groups, OC tails and arithmetic boundaries."""
from pathlib import Path
from fractions import Fraction
import argparse
import csv
import hashlib
import json
import random
from gemm_os1_ws32_w8a16_vectors import round_away, clip, write_hex

TOPS = {
    'w4a16_high_group': 'tb_Cluster_GEMM_W4A16_HighGroup',
    'w2a8_high_group': 'tb_Cluster_GEMM_W2A8_HighGroup',
    'w4a16_n6_tail': 'tb_Cluster_GEMM_W4A16_N6_Tail',
    'w4a16_round_clip': 'tb_Cluster_GEMM_W4A16_RoundClip',
}

CASES={
    'w4a16_high_group':dict(M=8,K=192,N=8,wb=4,ab=16,precision=4,first=4,split=1,base=0x80),
    'w2a8_high_group':dict(M=8,K=192,N=8,wb=2,ab=8,precision=1,first=6,split=7,base=0x90),
    'w4a16_n6_tail':dict(M=8,K=160,N=6,wb=4,ab=16,precision=4,first=4,split=1,base=0xa0),
    'w4a16_round_clip':dict(M=12,K=160,N=4,wb=4,ab=16,precision=4,first=4,split=1,base=0xb0),
}


def matmul(x,w):
    return [[sum(a*b[n] for a,b in zip(row,w)) for n in range(len(w[0]))] for row in x]


def rounded(value,multiplier,shift):
    return round_away(Fraction(value*multiplier)*Fraction(2)**shift)


def generate(directory,case,per_channel=True):
    cfg=CASES[case].copy()
    M,K,N,wb,ab=(cfg[k] for k in ['M','K','N','wb','ab'])
    out=Path(directory);out.mkdir(parents=True,exist_ok=True)
    rng=random.Random(0xE2E+list(CASES).index(case))
    if case=='w4a16_round_clip':
        assert per_channel
        zx=11
        x=[[zx]*K for _ in range(M)]
        w=[[int(k==n) for n in range(N)] for k in range(K)]
        columns=[[-5,-4,-3,-2,-1,0,1,2,3,4,5,6],
                 [-6,-5,-4,-3,-2,-1,0,1,2,3,4,6],
                 [-229,-228,-227,-101,-100,-99,26,27,28,29,0,1],
                 [-29,-28,-27,99,100,101,226,227,228,229,0,-1]]
        for m in range(M):
            for n in range(N):x[m][n]=columns[n][m]
        multipliers=[1,3,1,1];shifts=[-1,-2,0,0];zp=[0,1,100,-100]
        sx=Fraction(1);sw=[Fraction(1)]*N
        sy=[Fraction(2),Fraction(4,3),Fraction(1),Fraction(1)]
        output_zp=[zp[n]-rounded(-zx,multipliers[n],shifts[n]) for n in range(N)]
        x_real=[[Fraction(v-zx) for v in row] for row in x]
        w_real=[[Fraction(v) for v in row] for row in w]
    else:
        x_src=[[rng.randrange(-450,751) for _ in range(K)] for _ in range(M)]
        w_src=[[rng.randrange(-100,101)*(n+2) for n in range(N)] for _ in range(K)]
        xmin=min(0,min(map(min,x_src)));xmax=max(0,max(map(max,x_src)))
        alo=-(1<<(ab-1));ahi=(1<<(ab-1))-1;whi=(1<<(wb-1))-1
        sx=Fraction(xmax-xmin,ahi-alo)
        zx=clip(round_away(alo-Fraction(xmin)/sx),alo,ahi)
        shared=Fraction(max(abs(v) for row in w_src for v in row),whi)
        sw=[Fraction(max(abs(w_src[k][n]) for k in range(K)),whi) if per_channel else shared for n in range(N)]
        x=[[clip(round_away(Fraction(v)/sx)+zx,alo,ahi) for v in row] for row in x_src]
        w=[[clip(round_away(Fraction(v)/sw[n]),-whi,whi) for n,v in enumerate(row)] for row in w_src]
        x_real=[[Fraction(v) for v in row] for row in x_src]
        w_real=[[Fraction(v) for v in row] for row in w_src]
        real=matmul(x_real,w_real)
        ymin=min(0,min(map(min,real)));ymax=max(0,max(map(max,real)))
        sy=[Fraction(ymax-ymin,255)]*N
        output_zp=[clip(round_away(-128-Fraction(ymin)/sy[0]))]*N
        shifts=[-28+n%4 if per_channel else -28 for n in range(N)]
        multipliers=[round_away(sx*sw[n]/sy[n]*(1<<(-shifts[n]))) for n in range(N)]
        zp=[output_zp[n]+rounded(-zx*sum(w[k][n] for k in range(K)),multipliers[n],shifts[n]) for n in range(N)]
    raw=matmul(x,w)
    sums=[sum(w[k][n] for k in range(K)) for n in range(N)]
    centered=[[v-zx*sums[n] for n,v in enumerate(row)] for row in raw]
    before_clip=[[rounded(v,multipliers[n],shifts[n])+zp[n] for n,v in enumerate(row)] for row in raw]
    quant=[[clip(v) for v in row] for row in before_clip]
    original_quant=quant
    cim_quant=quant if per_channel else [[clip(rounded(v,multipliers[n],shifts[n])) for n,v in enumerate(row)] for row in raw]
    if not per_channel:
        quant=[[clip(cim_quant[m][n]+zp[n]) for n in range(N)] for m in range(M)]
    write_hex(out/'cim_golden.hex',(v for row in cim_quant for v in row),8)
    write_hex(out/'original_quant_reference.hex',(v for row in original_quant for v in row),8)

    real=matmul(x_real,w_real)
    ideal=[[clip(round_away(v/sy[n])+output_zp[n]) for n,v in enumerate(row)] for row in real]
    assert zx!=0 and all(-(1<<31)<=v<(1<<31) for row in raw for v in row)
    assert all(0<m<(1<<31) for m in multipliers)
    if per_channel and case!='w4a16_round_clip':assert len(set(sw))>1 and len(set(multipliers))>1
    coverage={
        'positive_half':sum(v*mult*Fraction(2)**s>0 and (v*mult*Fraction(2)**s).denominator==2
                            for row in raw for v,mult,s in zip(row,multipliers,shifts)),
        'negative_half':sum(v*mult*Fraction(2)**s<0 and (v*mult*Fraction(2)**s).denominator==2
                            for row in raw for v,mult,s in zip(row,multipliers,shifts)),
        'clip_low':sum(v<-128 for row in before_clip for v in row),
        'clip_high':sum(v>127 for row in before_clip for v in row),
        'exact_low':sum(v==-128 for row in before_clip for v in row),
        'exact_high':sum(v==127 for row in before_clip for v in row),
    }
    if case=='w4a16_round_clip':assert all(v>0 for v in coverage.values()),coverage
    maps=[]
    for start in range(0,N,4):
        mapping=[n if n<N else -1 for n in range(start,start+4)]
        if case=='w4a16_n6_tail' and start==4:mapping=[4,-1,5,-1]
        maps.append(mapping)
    phases=ab//4;kr=256//wb;count=wb
    lane_base=4*(cfg['first']//count)
    # Route expectations are explicit mathematical group positions, not RTL helpers.
    en=((1<<count)-1)<<cfg['first']
    slots=sum(local<<(3*(cfg['first']+local)) for local in range(count))
    rows=[]
    with (out/'weight_layout.csv').open('w',newline='',encoding='utf-8') as f:
        wr=csv.writer(f);wr.writerow(['n_tile','macro','address','local_oc','logical_n','k_first','k_last'])
        for tile,mapping in enumerate(maps):
            for macro in range(8):
                row=0;k0=(macro-cfg['first'])*kr
                if cfg['first']<=macro<cfg['first']+count:
                    for c,n in enumerate(mapping):
                        for j in range(kr):
                            value=w[k0+j][n] if n>=0 and k0+j<K else 0
                            row|=(value&((1<<wb)-1))<<(256*c+wb*j)
                        wr.writerow([tile,macro,hex(cfg['base']+tile),c,n,k0,min(K-1,k0+kr-1)])
                rows.append(row)
    planes=[sum((((x[m][k] if k<K else 0)&((1<<ab)-1))>>(4*ph)&15)<<(4*k) for k in range(256))
            for m in range(M) for ph in range(phases)]
    for name,matrix,bits in [('x_q.hex',x,16),('w_q.hex',w,8),('raw_golden.hex',raw,32),('quant_golden.hex',quant,8)]:
        write_hex(out/name,(v for row in matrix for v in row),bits)
    for name,values,bits in [('weight_rows.hex',rows,1024),('act_planes.hex',planes,1024),
                             ('requant_multiplier.hex',multipliers,32),('requant_shift.hex',shifts,10),('requant_zp.hex',zp,32)]:
        write_hex(out/name,values,bits)
    first_raw=phases+(3 if count==2 else 4)
    config=[M,K,N,wb,ab,cfg['precision'],cfg['first'],count,cfg['split'],en,slots,cfg['base'],lane_base,
            first_raw,len(maps),int(per_channel),zx]
    (out/'case_config.txt').write_text(' '.join(map(str,config))+'\n',encoding='ascii')
    (out/'channel_map.txt').write_text('\n'.join(' '.join(map(str,row)) for row in maps)+'\n',encoding='ascii')
    with (out/'matrix_golden.csv').open('w',newline='',encoding='utf-8') as f:
        wr=csv.writer(f);wr.writerow(['m','n','raw','quant','centered','before_clip','ideal_quant'])
        for m in range(M):
            for n in range(N):wr.writerow([m,n,raw[m][n],quant[m][n],centered[m][n],before_clip[m][n],ideal[m][n]])
    for name,matrix in [('x_real.csv',x_real),('w_real.csv',w_real),('y_real_golden.csv',real)]:
        with (out/name).open('w',newline='',encoding='utf-8') as f:csv.writer(f).writerows([[str(v) for v in row] for row in matrix])
    with (out/'input_schedule.csv').open('w',newline='',encoding='utf-8') as f:
        wr=csv.writer(f);wr.writerow(['n_tile','m','accept_cycle','raw_cycle','quant_cycle'])
        for tile in range(len(maps)):
            for m in range(M):wr.writerow([tile,m,m*(phases+1),m*(phases+1)+first_raw,m*(phases+1)+first_raw+1])
    meta=dict(cfg,case=case,weight_quantization='per-channel' if per_channel else 'per-tensor',
              act_zp=zx,weight_zp=0,act_scale=str(sx),weight_channel_scales=[str(v) for v in sw],
              multiplier=multipliers,shift=shifts,merged_zp=zp,output_zp_reference=output_zp,
              channel_map=maps,raw_lane_base=lane_base,first_raw=first_raw,first_quant=first_raw+1,
              os_cnt=1,ws_cnt=M,as_cnt=1,coverage=coverage,
              ideal_quant_max_error=max(abs(ideal[m][n]-quant[m][n]) for m in range(M) for n in range(N)))
    meta.update(tensor_zp_in_tb=not per_channel,tensor_double_saturation=not per_channel,
                original_algorithm_max_difference=max(abs(quant[m][n]-original_quant[m][n]) for m in range(M) for n in range(N)))
    (out/'gemm_metadata.json').write_text(json.dumps(meta,indent=2)+'\n',encoding='utf-8')
    (out/'vectors.sha256').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n'
        for p in sorted(out.iterdir()) if p.is_file() and p.name!='vectors.sha256' and not p.name.startswith('gemm_observed')),encoding='ascii')
    return meta


def verify_outputs(directory):
    directory=Path(directory)
    def read(name):
        with (directory/name).open(encoding='utf-8') as f:rows=list(csv.DictReader(f))
        return rows,{(int(r['m']),int(r['n'])):(int(r['raw']),int(r['quant'])) for r in rows}
    expected_rows,expected=read('matrix_golden.csv');rows,actual=read('gemm_observed_matrix.csv')
    assert len(rows)==len(expected_rows)==len(actual) and actual==expected
    print(f'PASS GEMM scenario Python comparison: {len(rows)} raw and INT8 elements',flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path);parser.add_argument('--case',choices=CASES,required=True)
    parser.add_argument('--per-tensor',action='store_true')
    args=parser.parse_args();print(json.dumps(generate(args.output,args.case,not args.per_tensor),indent=2))
