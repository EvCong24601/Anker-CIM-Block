"""Exact matrix golden and physical vectors for one-Cluster W8A16 OS2/AS4."""
from fractions import Fraction
from pathlib import Path
import argparse
import csv
import hashlib
import json
import random
from gemm_os1_ws32_w8a16_vectors import round_away,clip,write_hex

M,K,N=32,512,16
BASE_ADDR=0x60


def matmul(a,b):
    return [[sum(a[m][k]*b[k][n] for k in range(K)) for n in range(N)] for m in range(M)]


def generate(directory,seed=0x3251216,per_channel=False):
    out=Path(directory);out.mkdir(parents=True,exist_ok=True)
    rng=random.Random(seed)
    x_src=[[rng.randrange(-1400,2501) for _ in range(K)] for _ in range(M)]
    w_src=[[rng.randrange(-850,851)+(n-7)*21 for n in range(N)] for _ in range(K)]
    xmin=min(0,min(map(min,x_src)));xmax=max(0,max(map(max,x_src)))
    sx=Fraction(xmax-xmin,1024*65535)
    zx=clip(round_away(-32768-Fraction(xmin,1024)/sx),-32768,32767)
    sw=Fraction(max(abs(v) for row in w_src for v in row),2048*127)
    sw_channels=[Fraction(max(abs(w_src[k][n]) for k in range(K)),2048*127) if per_channel else sw for n in range(N)]
    x=[[clip(round_away(Fraction(v,1024)/sx)+zx,-32768,32767) for v in row] for row in x_src]
    w=[[clip(round_away(Fraction(v,2048)/sw_channels[n]),-127,127) for n,v in enumerate(row)] for row in w_src]
    y_src=matmul(x_src,w_src)
    ymin=Fraction(min(0,min(map(min,y_src))),1024*2048)
    ymax=Fraction(max(0,max(map(max,y_src))),1024*2048)
    sy=(ymax-ymin)/255;zy=clip(round_away(-128-ymin/sy))
    scale=sx*sw/sy;shift=-31;multiplier=round_away(scale*(1<<31))
    assert 0<multiplier<(1<<31)
    effective=Fraction(multiplier,1<<31)
    output_scales=[sy for n in range(N)]
    shifts=[-31+n%4 if per_channel else shift for n in range(N)]
    multipliers=[round_away(sx*sw_channels[n]/output_scales[n]*(1<<(-shifts[n]))) for n in range(N)]
    effective_scales=[Fraction(multipliers[n],1<<(-shifts[n])) for n in range(N)]
    sums=[sum(w[k][n] for k in range(K)) for n in range(N)]
    correction=[-zx*v for v in sums]
    # The producer supplies an effective per-channel INT32 zp, including the
    # input-offset term. There is no separate correction interface in RTL.
    output_zp=[clip(round_away(-128-Fraction(min(0,min(y_src[m][n] for m in range(M))),1024*2048)/output_scales[n])) for n in range(N)]
    zp=[output_zp[n]+round_away(correction[n]*effective_scales[n]) for n in range(N)]
    raw=matmul(x,w)
    centered=[[raw[m][n]+correction[n] for n in range(N)] for m in range(M)]
    q=[[clip(round_away(v*effective_scales[n])+zp[n]) for n,v in enumerate(row)] for row in raw]
    centered_q=[[clip(round_away(v*effective_scales[n])+output_zp[n]) for n,v in enumerate(row)] for row in centered]
    ideal=[[clip(round_away(Fraction(v,1024*2048)/output_scales[n])+output_zp[n]) for n,v in enumerate(row)] for row in y_src]
    rounding_error=max(abs(q[m][n]-centered_q[m][n]) for m in range(M) for n in range(N))
    ideal_error=max(abs(q[m][n]-ideal[m][n]) for m in range(M) for n in range(N))
    assert rounding_error<=1 and zx!=0 and len(set(zp))>1
    assert min(map(min,q))<0<max(map(max,q))
    assert all(-(1<<31)<=v<(1<<31) for a in (raw,centered) for row in a for v in row)
    for name,matrix,bits in [('x_q.hex',x,16),('w_q.hex',w,8),('raw_golden.hex',raw,32),
                             ('centered_golden.hex',centered,32),('quant_golden.hex',q,8),('ideal_quant.hex',ideal,8)]:
        write_hex(out/name,(v for row in matrix for v in row),bits)
    write_hex(out/'requant_zp.hex',zp,32)
    write_hex(out/'requant_multiplier.hex',multipliers,32)
    write_hex(out/'requant_shift.hex',shifts,10)
    for name,matrix,den in [('x_real.csv',x_src,1024),('w_real.csv',w_src,2048),('y_real_golden.csv',y_src,1024*2048)]:
        with (out/name).open('w',newline='',encoding='utf-8') as f:
            csv.writer(f).writerows([[v/den for v in row] for row in matrix])
    (out/'requant_params.txt').write_text(f'{multiplier} {shift} {zy} {zx}\n',encoding='ascii')
    weight_rows=[]
    with (out/'weight_layout.csv').open('w',newline='',encoding='utf-8') as f:
        wr=csv.writer(f);wr.writerow(['k_tile','as_context','macro','row_address','k_start','k_end','n_start','n_end'])
        for tile in range(2):
            for cx in range(4):
                for macro in range(8):
                    k0=tile*256+macro*32;n0=cx*4
                    weight_rows.append(sum((w[k0+j][n0+oc]&255)<<(256*oc+8*j) for oc in range(4) for j in range(32)))
                    wr.writerow([tile,cx,macro,f'0x{BASE_ADDR+tile*4+cx:02x}',k0,k0+31,n0,n0+3])
    write_hex(out/'weight_rows.hex',weight_rows,1024)
    planes=[]
    for m in range(M):
        for tile in range(2):
            for ph in range(4):
                planes.append(sum(((x[m][tile*256+j]&65535)>>(4*ph)&15)<<(4*j) for j in range(256)))
    write_hex(out/'act_planes.hex',planes,1024)
    # Exact partial results use the mathematical digit expansion, independent
    # of the controller/tree/Context addressing in RTL.
    histories=[]
    for m in range(M):
        running=[[0]*4 for _ in range(4)]
        for tile in range(2):
            for ph in range(4):
                for cx in range(4):
                    for oc in range(4):
                        n=4*cx+oc;s=0
                        for j in range(256):
                            digit=(x[m][tile*256+j]&65535)>>(4*ph)&15
                            if ph==3 and digit>=8:digit-=16
                            s+=digit*w[tile*256+j][n]
                        running[cx][oc]+=s*(1<<(4*ph))
                        assert -(1<<31)<=running[cx][oc]<(1<<31)
                        histories.append(running[cx][oc])
    write_hex(out/'psum_history_golden.hex',histories,32)
    with (out/'input_schedule.csv').open('w',newline='',encoding='utf-8') as f:
        wr=csv.writer(f);wr.writerow(['row_m','row_relative_cycle','k_tile','command_context','weight_address','act_slice','issue_context','issue_slice'])
        for m in range(M):
            for tile in range(2):
                for t in range(17):
                    wr.writerow([m,tile*17+t,tile,t if t<4 else '',f'0x{BASE_ADDR+4*tile+t:02x}' if t<4 else '',t if t<4 else '',(t-1)%4 if t else '',(t-1)//4 if t else ''])
    with (out/'matrix_golden.csv').open('w',newline='',encoding='utf-8') as f:
        wr=csv.writer(f);wr.writerow(['m','n','raw','weight_sum','input_correction','centered_psum','requant_zp','quant','centered_quant','ideal_float_quant'])
        for m in range(M):
            for n in range(N):wr.writerow([m,n,raw[m][n],sums[n],correction[n],centered[m][n],zp[n],q[m][n],centered_q[m][n],ideal[m][n]])
    meta=dict(M=M,K=K,N=N,seed=seed,clusters=1,os_cnt=2,as_cnt=4,ws_cnt=1,precision='W8A16',
              weight_addresses=list(range(BASE_ADDR,BASE_ADDR+8)),weight_bytes=8192,
              split_mask=0,act_slots=list(range(8)),act_zp=zx,weight_zp=0,output_zp_reference=output_zp,base_output_zp=zy,
              act_scale=str(sx),weight_scale=str(sw),output_scale=str(sy),requant_scale=str(scale),
              multiplier=multiplier,shift=shift,effective_scale=str(effective),requant_zp=zp,
              per_channel_scale=per_channel,channel_multipliers=multipliers,channel_shifts=shifts,
              weight_quantization='per-channel' if per_channel else 'per-tensor',weight_channel_scales=[str(v) for v in sw_channels],
              channel_output_scales=[str(v) for v in output_scales],scale_context_bits=672,
              weight_column_sums=sums,input_offset_reference=correction,zp_context_depth=4,zp_lanes=4,zp_bits=512,
              compensation_rounding_max_difference=rounding_error,ideal_quant_max_error=ideal_error,
              raw_min=min(map(min,raw)),raw_max=max(map(max,raw)))
    (out/'gemm_metadata.json').write_text(json.dumps(meta,indent=2)+'\n',encoding='utf-8')
    (out/'vectors.sha256').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n'
        for p in sorted(out.iterdir()) if p.is_file() and p.name!='vectors.sha256' and not p.name.startswith('gemm_observed')),encoding='ascii')
    return meta


def verify_outputs(directory):
    """Compare the simulated OS2/AS4 matrix against this module's own M/N golden."""
    out=Path(directory)
    with (out/'matrix_golden.csv').open(encoding='utf-8') as f:
        expected={(int(r['m']),int(r['n'])):(int(r['raw']),int(r['quant'])) for r in csv.DictReader(f)}
    with (out/'gemm_observed_matrix.csv').open(encoding='utf-8') as f:
        rows=list(csv.DictReader(f))
    assert len(expected)==M*N and len(rows)==M*N,'OS2/AS4 observed matrix is not M*N'
    actual={(int(r['m']),int(r['n'])):(int(r['raw']),int(r['quant'])) for r in rows}
    assert actual==expected,'Observed OS2/AS4 GEMM matrix differs from Python integer golden'
    print(f'PASS Python OS2/AS4 output comparison: {M*N} raw and {M*N} INT8 matrix elements',flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path)
    parser.add_argument('--per-channel',action='store_true')
    args=parser.parse_args()
    print(json.dumps(generate(args.output,per_channel=args.per_channel),indent=2))
