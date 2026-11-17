"""Generate 42 current-RTL issue-relative timing examples."""
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
COUNTS = ((1,1,1),(1,1,2),(1,2,1),(2,1,1),(2,2,1),(2,1,2))
NAMES = ('W2A4','W2A8','W4A4','W4A8','W4A16','W8A8','W8A16')
ABITS = (4,8,4,8,16,8,16)

def examples():
    for case,(os,ws,ac) in enumerate(COUNTS,1):
        for precision,name in enumerate(NAMES):
            phases=ABITS[precision]//4
            latency=3 if precision<2 else 4 if precision<5 else 5
            split,en=('07','55') if precision<2 else ('01','33') if precision<5 else ('00','0F')
            order=([(t,c,p) for t in range(os) for p in range(phases) for c in range(ac)] if ac>1 else
                   [(t,c,p) for t in range(os) for c in range(ws) for p in range(phases)])
            rows=[]
            for issue,(tile,ctx,phase) in enumerate(order):
                tmp=issue+latency
                psum=tmp+1 if ac>1 or (os>1 and phase==phases-1) else None
                final=tile==os-1 and phase==phases-1
                publish=(psum if os>1 or ac>1 else tmp) if final else None
                rows.append(dict(issue=issue,tile=tile,ctx=ctx,phase=phase,tmp=tmp,psum=psum,
                                 publish=publish,sample=None if publish is None else publish+1))
            yield dict(case=case,os=os,ws=ws,ac=ac,precision=precision,name=name,phases=phases,
                       latency=latency,split=split,en=en,rows=rows)

def cycle(v):return '—' if v is None else f'C{v}'

def main():
    lines=['# Cluster 当前逐拍写入表','','外部命令为 102 bit，每任务握手一次；权重地址和 ACT 独立握手。', '',
      '[流水总览](Cluster_Pipeline.svg) · [实测交接图](Cluster_Issue_Timing.svg) · [输入调度](Cluster_Input_Overlap.md) · [接口契约](Cluster_Raw_Output.md)', '',
      '## 周期口径','',
      '以下 42 组以任务首次内部 issue 为 C0，假定操作数及时供给、各次 issue 连续。C0 不代表命令或 ACT 的外部接收沿。输入等待会移动后续 issue，写入及发布沿须按该笔实际 issue 计算。','',
      '相对每次 issue：输入 I0、CSA I1、Macro 结果 I2。Reduce-1/2、Reduce-4、Reduce-8 在 I3/I4/I5 写 tmp；需要 Psum 时下一沿写回。归约宽度取决于 split 结构端点，不能按 enable 的 popcount 或仅按 W 精度推断。','',
      '“发布”为最终值写入后 psum_valid 拉高的沿，“采样”为下一上升沿。非最终 phase/Tile 只更新历史。TMP 模式为 OS=AS=1；OS Psum 为 OS>1 且 AS=1；AS Psum 为 AS>1。WS 不独立增加写回一级。','',
      'AS 按 Tile→phase→Context 发射，每 phase 写 Psum；其他模式按 Tile→Context→phase 发射，在 tmp 前融合，OS Psum 只在末 phase 写回。所有中间存储均须适合 signed32，没有硬件饱和保护。','',
      '## 42 组标准示例','',
      'K128 示例采用 W2 split=07/EN=55、W4 split=01/EN=33、W8 split=00/EN=0F，结构端点分别为 2/4/8 路，OC mask=FFFFFFFF。每 Tile K=128，总 K=128×OS；物理行尾部补零。完整 K256 槽映射见接口契约。']
    for e in examples():
        lines+=['',f"### A{e['case']} precision={e['precision']} {e['name']} OS={e['os']} WS={e['ws']} AS={e['ac']}",'',
          f"split=7'h{e['split']}，EN=8'h{e['en']}，issue→tmp={e['latency']} 拍。命令 1 次、地址 {e['os']*e['ac']} 次、ACT plane {e['os']*e['ws']*e['phases']} 次。",'',
          '| issue 沿 | Tile | Context | phase | 写 tmp 沿 | 写 Psum 沿 | 最终发布沿 | 下游采样沿 |',
          '|---|---:|---:|---:|---|---|---|---|']
        for r in e['rows']:
            lines.append('| '+' | '.join([cycle(r['issue']),str(r['tile']),str(r['ctx']),str(r['phase']),cycle(r['tmp']),cycle(r['psum']),cycle(r['publish']),cycle(r['sample'])])+' |')
    lines+=['','## 连续任务','',
      '兼容性检查覆盖当前输入任务、全部实际在途事务和待写回的 Psum tmp。兼容新 cmd 最早在旧任务末次 issue 沿接收，首操作数及时到达时下一沿 issue。要求同 A 位宽、同累加模式，以及同 split 或单一有效归约宽度下的同路径类别。混合宽度仅保留同 split 规则；空任务不能掩盖更早的在途约束。','',
      '不兼容配置等待旧结果排空，最早在采样最后一个旧结果的同沿接收新 cmd。精确规则见 [控制切换说明](Cluster_Control_Switching_README.md)。','',
      '生成器：`python RTL/cluster/tb/py/generate_readme.py`。不调用旧 combined-command 的 buffer_schedule.py 或 audit_latency.py。','']
    (REPO/'docs/Cluster_Timing_Tables.md').write_text('\n'.join(lines),encoding='utf8')

if __name__=='__main__':main()
