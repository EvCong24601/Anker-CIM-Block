"""Generate an asymmetric-A16 / symmetric-W8 WS GEMM and exact integer golden."""
from fractions import Fraction
from pathlib import Path
import argparse
import csv
import hashlib
import json
import random

M, K, N = 32, 128, 16
BASE_ADDR = 0x40


def round_away(value):
    value = Fraction(value)
    q, r = divmod(abs(value.numerator), value.denominator)
    q += 2*r >= value.denominator
    return -q if value < 0 else q


def clip(value, lo=-128, hi=127):
    return min(hi, max(lo, value))


def matmul(a, b):
    # Deliberately full matrix integers, independent of Macro packing/RTL.
    return [[sum(a[m][k]*b[k][n] for k in range(K)) for n in range(N)] for m in range(M)]


def write_hex(path, values, bits):
    path.write_text(''.join(f'{v & ((1<<bits)-1):0{bits//4}x}\n' for v in values), encoding='ascii')


def generate(directory, seed=0x3212816, per_channel=False):
    out = Path(directory)
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(seed)
    # Fixed-point real matrices provide reproducible nonzero asymmetric ACT zp.
    x_src = [[rng.randrange(-1400, 2501) for _ in range(K)] for _ in range(M)]
    w_src = [[rng.randrange(-850, 851)+(n-7)*21 for n in range(N)] for _ in range(K)]
    x_min = min(0, min(map(min, x_src)))
    x_max = max(0, max(map(max, x_src)))
    sx = Fraction(x_max-x_min, 1024*65535)
    zx = clip(round_away(-32768-Fraction(x_min,1024)/sx), -32768, 32767)
    sw = Fraction(max(abs(v) for row in w_src for v in row), 2048*127)
    sw_channels=[Fraction(max(abs(w_src[k][n]) for k in range(K)),2048*127) if per_channel else sw for n in range(N)]
    x = [[clip(round_away(Fraction(v,1024)/sx)+zx,-32768,32767) for v in row] for row in x_src]
    w = [[clip(round_away(Fraction(v,2048)/sw_channels[n]),-127,127) for n,v in enumerate(row)] for row in w_src]
    # Calibrate ONE output tensor from the original real-valued matrix product.
    y_src = matmul(x_src, w_src)
    ymin = Fraction(min(0,min(map(min,y_src))),1024*2048)
    ymax = Fraction(max(0,max(map(max,y_src))),1024*2048)
    sy = (ymax-ymin)/255
    zy = clip(round_away(-128-ymin/sy))
    scale = sx*sw/sy
    shift = -31
    multiplier = round_away(scale*(1<<31))
    assert 0 < multiplier < (1<<31)
    effective_scale = Fraction(multiplier,1<<31)
    shifts=[-31+n%4 if per_channel else shift for n in range(N)]
    multipliers=[round_away(sx*sw_channels[n]/sy*(1<<(-shifts[n]))) for n in range(N)]
    effective_scales=[Fraction(multipliers[n],1<<(-shifts[n])) for n in range(N)]
    sums = [sum(w[k][n] for k in range(K)) for n in range(N)]
    correction = [-zx*v for v in sums]
    # Final interface contract: the producer folds input-offset compensation
    # into the per-channel INT32 zp. RTL consumes only raw, scale and this zp.
    zp = [zy+round_away(v*effective_scales[n]) for n,v in enumerate(correction)]
    raw = matmul(x,w)
    centered = [[raw[m][n]+correction[n] for n in range(N)] for m in range(M)]
    q = [[clip(round_away(v*effective_scales[n])+zp[n]) for n,v in enumerate(row)] for row in raw]
    centered_q = [[clip(round_away(v*effective_scales[n])+zy) for n,v in enumerate(row)] for row in centered]
    ideal_q = [[clip(round_away(Fraction(v,1024*2048)/sy)+zy) for v in row] for row in y_src]
    differences = [abs(q[m][n]-centered_q[m][n]) for m in range(M) for n in range(N)]
    errors = [abs(q[m][n]-ideal_q[m][n]) for m in range(M) for n in range(N)]
    assert zx != 0 and any(v<0 for row in x for v in row) and any(v>0 for row in x for v in row)
    assert len(set(correction))>1 and all(v != 0 for v in sums)
    assert max(differences)<=1
    assert all(-(1<<31)<=v<(1<<31) for matrix in (raw,centered) for row in matrix for v in row)
    assert min(map(min,q))<0<max(map(max,q))
    write_hex(out/'x_q.hex',(v for row in x for v in row),16)
    write_hex(out/'w_q.hex',(v for row in w for v in row),8)
    write_hex(out/'raw_golden.hex',(v for row in raw for v in row),32)
    write_hex(out/'centered_golden.hex',(v for row in centered for v in row),32)
    write_hex(out/'quant_golden.hex',(v for row in q for v in row),8)
    write_hex(out/'ideal_quant.hex',(v for row in ideal_q for v in row),8)
    write_hex(out/'requant_zp.hex',zp,32)
    write_hex(out/'requant_multiplier.hex',multipliers,32)
    write_hex(out/'requant_shift.hex',shifts,10)
    for name,matrix,denominator in [('x_real.csv',x_src,1024),('w_real.csv',w_src,2048),('y_real_golden.csv',y_src,1024*2048)]:
        with (out/name).open('w',newline='',encoding='utf-8') as f:
            csv.writer(f).writerows([[v/denominator for v in row] for row in matrix])
    (out/'requant_params.txt').write_text(f'{multiplier} {shift} {zy} {zx}\n',encoding='ascii')
    # Four sequential N4 tiles. W8 uses all eight Macros; K128 pads to K256.
    weight_rows=[]
    with (out/'weight_layout.csv').open('w',newline='',encoding='utf-8') as f:
        writer=csv.writer(f)
        writer.writerow(['cluster','n_tile','macro','row_address','k_start','k_end','n_start','n_end'])
        for tile in range(4):
            for macro in range(8):
                k0=macro*32
                n0=tile*4
                row=sum(((w[k0+j][n0+oc] if k0+j<K else 0)&255)<<(256*oc+8*j) for oc in range(4) for j in range(32))
                weight_rows.append(row)
                writer.writerow([0,tile,macro,f'0x{BASE_ADDR+tile:02x}',k0,k0+31,n0,n0+3])
    write_hex(out/'weight_rows.hex',weight_rows,1024)
    planes=[]
    with (out/'input_schedule.csv').open('w',newline='',encoding='utf-8') as f:
        writer=csv.writer(f)
        writer.writerow(['n_tile','tile_relative_cycle','row_m','slice','command_valid','weight_address','internal_issue_row','internal_issue_slice'])
        for m in range(M):
            for ph in range(4):
                planes.append(sum(((x[m][k]&65535)>>(4*ph)&15)<<(4*k) for k in range(K)))
        for tile in range(4):
            for m in range(M):
                for t in range(5):
                    writer.writerow([tile,5*m+t,m,t if t<4 else '',int(t==0),f'0x{BASE_ADDR+tile:02x}' if t==0 else '',m if t else '',t-1 if t else ''])
    write_hex(out/'act_planes.hex',planes,1024)
    with (out/'matrix_golden.csv').open('w',newline='',encoding='utf-8') as f:
        writer=csv.writer(f)
        writer.writerow(['m','n','raw','weight_sum','input_correction','centered_psum','requant_zp','quant','centered_quant','ideal_float_quant'])
        for m in range(M):
            for n in range(N):writer.writerow([m,n,raw[m][n],sums[n],correction[n],centered[m][n],zp[n],q[m][n],centered_q[m][n],ideal_q[m][n]])
    meta=dict(M=M,K=K,N=N,seed=seed,clusters=1,n_tiles=4,macros_per_k_group=8,n_groups_per_cluster=1,padded_K=256,
              precision='W8A16',os_cnt=1,ws_cnt=32,as_cnt=1,weight_addresses=list(range(BASE_ADDR,BASE_ADDR+4)),
              split_mask=0,act_slots=list(range(8)),act_zp=zx,weight_zp=0,output_zp=zy,
              act_scale=str(sx),weight_scale=str(sw),output_scale=str(sy),requant_scale=str(scale),
              multiplier=multiplier,shift=shift,effective_scale=str(effective_scale),requant_zp=zp,
              weight_quantization='per-channel' if per_channel else 'per-tensor',
              weight_channel_scales=[str(v) for v in sw_channels],per_channel_scale=per_channel,
              channel_multipliers=multipliers,channel_shifts=shifts,
              weight_column_sums=sums,input_offset_reference=correction,compensation_rounding_max_difference=max(differences),
              ideal_quant_max_error=max(errors),ideal_quant_differences=sum(v!=0 for v in errors),
              raw_min=min(map(min,raw)),raw_max=max(map(max,raw)),quant_min=min(map(min,q)),quant_max=max(map(max,q)))
    (out/'gemm_metadata.json').write_text(json.dumps(meta,indent=2)+'\n',encoding='utf-8')
    (out/'vectors.sha256').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n'
                                       for p in sorted(out.iterdir()) if p.is_file() and p.name!='vectors.sha256'
                                       and not p.name.startswith('gemm_observed')),encoding='ascii')
    return meta


def verify_outputs(directory):
    out=Path(directory)
    with (out/'matrix_golden.csv').open(encoding='utf-8') as f:
        expected={(int(r['m']),int(r['n'])):(int(r['raw']),int(r['quant'])) for r in csv.DictReader(f)}
    with (out/'gemm_observed_matrix.csv').open(encoding='utf-8') as f:
        rows=list(csv.DictReader(f))
    assert len(rows)==M*N
    actual={(int(r['m']),int(r['n'])):(int(r['raw']),int(r['quant'])) for r in rows}
    assert actual==expected,'Observed GEMM matrix differs from Python integer golden'
    print(f'PASS Python GEMM output comparison: {M*N} raw and {M*N} INT8 matrix elements',flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path)
    parser.add_argument('--seed',type=lambda v:int(v,0),default=0x3212816)
    parser.add_argument('--per-channel',action='store_true',help='symmetric W8 quantization independently for each output column')
    args=parser.parse_args()
    print(json.dumps(generate(args.output,args.seed,per_channel=args.per_channel),indent=2))
