"""Regenerate the current handoff figures from checked TIMING_FIGURE CSVs.

Render SVGs to PNG with an SVG renderer after running this script.
"""
from pathlib import Path
from html import escape
import csv
import xml.etree.ElementTree as ET

D=Path(__file__).resolve().parent
J=list(csv.DictReader((D/'timing_data/channel_cycles.csv').open(encoding='utf8')))
E=list(csv.DictReader((D/'timing_data/channel_events.csv').open(encoding='utf8')))
assert len(J)==5
assert [(int(j['last_issue']),int(j['last_output'])) for j in J]==[(134,138),(135,139),(138,142),(142,146),(148,154)]

# Keep the detailed ICG layout, correcting all current interface/gating labels.
p=D/'Cluster_Pipeline_ICG.svg'
s=p.read_text(encoding='utf8')
changes={
 '命令 · 103 bit':'命令 · 102 bit',
 '按精度 / DW 模式选槽':'按 W 精度选择完整 ACT 槽',
 'I1 · 局部和暂存':'I1 · CSA 暂存',
 '乘积、融合、求和后暂存':'每 OC ICG · 共 32 门',
 '普通 W8/W4/W2 开 1/2/3 个 bank；DW 仅开低 bank':'W8/W4/W2 分别开 1/2/3 个 ACT bank；K256 使用完整槽',
 '配置比较与排空检查':'全在途兼容与排空检查',
 'issue 时生成首 / 末 Tile 标志，':'issue 捕获 51 bit cfg 与元数据，',
 '每条路径分别捕获 phase、Context 和 Tile 标志。':'分别保存 cfg、phase、Context 和 Tile 标志。',
 '>raw Context<':'>raw 配置 / Context<',
 '每条路径仅在发布 Psum 结果时更新。':'Psum 发布时保存本笔 51 bit cfg 与 Context。',
 'Macro 中间拍':'CSA 暂存',
 '555（Cluster 本体） + 72（8 个 Macro） + 24（归约树） = 651':'555（Cluster 本体） + 104（8 个 Macro） + 24（归约树） = 683',
}
for a,b in changes.items():s=s.replace(a,b)
if 'CPA + 符号修正' not in s:
 s=s.replace('<g data-module="I2 · Macro 结果">','<text x="816" y="648" class="small">CPA + 符号修正</text>\n<g data-module="I2 · Macro 结果">')
p.write_text(s,encoding='utf8')

class Figure:
 def __init__(self,w,h,title,sub):
  self.w,self.h=w,h
  self.a=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img"><title>{escape(title)}</title>',
   '''<defs><marker id="a" viewBox="0 0 10 8" refX="9" refY="4" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 0L10 4L0 8Z" fill="#486271"/></marker></defs>
<style>text{font-family:"Microsoft YaHei","Segoe UI",sans-serif;fill:#17394a}.title{font-size:36px;font-weight:700}.sub{font-size:18px}.head{font-size:23px;font-weight:700}.body{font-size:18px}.small{font-size:16px}.mono{font:17px Consolas,"Microsoft YaHei",monospace}.stage{font:600 17px Consolas,"Microsoft YaHei",monospace}.dff{fill:#eaf3f8;stroke:#386885;stroke-width:1.7}.comb{fill:#fafbfa;stroke:#657a82;stroke-width:1.7;stroke-dasharray:6 4}.cell{fill:#eff4f7}.write{fill:#e3f3ed}.psum{fill:#fbefdb}.sample{fill:#dcebe5}.panel{fill:#fafcfc;stroke:#d5dfe4}.data{fill:none;stroke:#486271;stroke-width:2}.rule{stroke:#d5dfe4;stroke-width:1}</style>''',f'<rect width="{w}" height="{h}" fill="white"/>']
  self.text(40,55,title,'title');self.text(40,94,sub,'sub');self.line(40,118,w-40,118)
 def text(self,x,y,t,c='body',anchor='start'):
  self.a.append(f'<text x="{x}" y="{y}" class="{c}" text-anchor="{anchor}">{escape(str(t))}</text>')
 def rect(self,x,y,w,h,c='cell'):
  self.a.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="4" class="{c}"/>')
 def line(self,x,y,x2,y2):self.a.append(f'<line x1="{x}" y1="{y}" x2="{x2}" y2="{y2}" class="rule"/>')
 def arrow(self,x,y,x2,y2):self.a.append(f'<path d="M{x} {y} H{x2} V{y2}" class="data" marker-end="url(#a)"/>')
 def box(self,x,y,w,h,title,sub,c='dff'):
  self.rect(x,y,w,h,c);self.text(x+13,y+27,title,'head');self.text(x+13,y+53,sub,'small')
 def save(self,name):
  self.text(self.w-40,self.h-18,'RTL e737282 · 2026-11-17 · CSA arithmetic golden','small','end')
  self.a.append('</svg>');(D/name).write_text('\n'.join(self.a)+'\n',encoding='utf8')

f=Figure(2160,1180,'Cluster 三通道实测流水与交接','A1–A4：W4A4、两路归约、OS=WS=AS=1；B1：四路归约、OS=2。命令均为 102 bit。')
f.text(40,159,'实线方格标出寄存器写入沿；SAMP 标出下游采样沿。绝对周期来自当前 TIMING_FIGURE 激励。','body')
start,step=285,82
for c in range(133,155):f.text(start+(c-133)*step+38,202,f'C{c}','stage','middle')
rows=[('A1',134,0),('A2',135,0),('A3',138,0),('A4',142,0),('B1 · Tile0',147,1),('B1 · Tile1',148,1)]
for i,(name,n,deep) in enumerate(rows):
 y=220+i*63
 f.text(40,y+27,name,'head');f.text(40,y+49,f'issue C{n}','small')
 cells=[(n,'IN','cell'),(n+1,'CSA','cell'),(n+2,'MAC','cell')]
 if deep:cells +=[(n+3,'PAIR','cell'),(n+4,'TMP','write'),(n+5,'PSUM','psum')]
 else:cells +=[(n+3,'TMP','write')]
 if name!='B1 · Tile0':cells +=[(n+(6 if deep else 4),'SAMP','sample')]
 for c,label,cls in cells:
  x=start+(c-133)*step;f.rect(x,y,76,42,cls);f.text(x+38,y+27,label,'stage','middle')
f.text(40,631,'IN：Macro 输入；CSA：中间暂存；MAC：CPA 结果；PAIR：归约转发；TMP / PSUM：对应存储写入。','small')
f.line(40,650,2120,650)
f.text(40,689,'输入沿前的握手值与输出采样','head')
f.text(700,689,'1/1 表示该路在本沿握手；输出行显示本沿采样的 mask。','body')
for c in range(133,155):f.text(start+(c-133)*step+38,731,f'{c}','stage','middle')
events={int(e['cycle']):e for e in E}
for r,(label,keys) in enumerate([('cmd V/R',('cmd_valid','cmd_ready')),('weight V/R',('weight_valid','weight_ready')),('ACT V/R',('act_valid','act_ready'))]):
 y=750+r*49;f.text(40,y+25,label,'mono')
 for c in range(133,155):
  e=events[c];v,ready=e[keys[0]],e[keys[1]];x=start+(c-133)*step
  f.rect(x,y,76,35,'write' if v==ready=='1' else 'cell');f.text(x+38,y+24,f'{v}/{ready}','mono','middle')
f.text(40,926,'issue','mono');f.text(40,974,'输出采样','mono')
for c in range(133,155):
 e=events[c];x=start+(c-133)*step
 if e['issue']=='1':f.rect(x,902,76,35,'write');f.text(x+38,926,'1','stage','middle')
 if int(e['psum_valid_hex'],16):
  f.rect(x,950,76,35,'sample');f.text(x+38,974,'FFFF' if e['psum_valid_hex']=='0000ffff' else 'FF','stage','middle')
f.text(40,1022,'C138：A3 用迟到的地址 issue，同时接收 A4 cmd；该沿 weight 属于 A3。C139 才接收 A4 地址，并捕获 A3 的 CSA。','body')
f.text(40,1058,'C142：A4 的 ACT 到达并直通 issue，同沿采样 A3。C145 写 A4 tmp，C146 采样 A4，同沿接收不兼容 B1 cmd。','body')
f.text(40,1094,'B1 两次 issue 为 C147/C148；Psum 分别在 C152/C153 写入，末 Tile 最终值在 C153 沿后有效，C154 采样。','body')
f.text(40,1130,'数据：docs/timing_data/channel_cycles.csv 与 channel_events.csv；复现入口见 Testbench_Guide.md。','small')
f.save('Cluster_Issue_Timing.svg')

f=Figure(2040,1070,'A3 / A4 交接的输入归属与两拍 Macro','同一条三通道通路的三个真实采样沿；外部 payload 归属按各路剩余输入数量独立判定。W4A4、两路归约、TMP 模式。')
panels=[
 ('C138','A3 发射，同时接收 A4 cmd','A4 · valid/ready = 1/1','无 ACT · 0/1','A3 地址 0x02 · 1/1',
  '当前 ACT 缓冲 → A3','权重地址直通 → A3','issue = 1 · 使用旧任务 A3 配置',
  'A3：捕获 ACT，刷新 SRAM 行','A2：CPA 结果已在 C137 保存',
  ['A4 cmd 在本沿接收，沿后成为前端任务。','该路 weight 最后一个 beat 仍属于 A3。','A4 自己的地址要到下一沿才能接收。']),
 ('C139','A4 收地址，A3 写 CSA','无 cmd · 0/0','无 ACT · 0/1','A4 地址 0x03 · 1/1',
  '没有 A4 ACT → 等待','A4 地址写入标量缓冲','issue = 0 · 前端等待 ACT',
  '无新 Macro 输入，SRAM 保持','A3：CSA 暂存；C140 才写 Macro 结果',
  ['A4 地址沿后有效，weight_available = 1。','A3 配置继续随自身 metadata 推进。','A3 在 C141 写 tmp，C142 被下游采样。']),
 ('C142','A4 ACT 直通并发射','无 cmd · 0/1','A4 ACT · 1/1','无新地址 · 0/0',
  '当前 ACT 直通 → A4','已缓冲地址 0x03 → A4','issue = 1 · 两路操作数齐备',
  'A4：捕获 ACT，刷新 SRAM 行','A3：本沿采样最终 raw 结果',
  ['A4 ACT 在同沿用完：act_buffer_we = 0。','W4 的 Macro ACT bank 时钟为 011。','A4 在 C143 写 CSA，C144 写 Macro 结果。'])]
for i,(c,title,cmd,act,w,asel,wsel,iss,inp,ret,notes) in enumerate(panels):
 x=40+i*666
 f.rect(x,145,626,739,'panel');f.text(x+20,183,c,'title');f.text(x+140,181,title,'head')
 for yy,label,value in [(233,'CMD',cmd),(278,'ACT',act),(323,'weight',w)]:
  f.text(x+20,yy,label,'stage');f.text(x+120,yy,value,'body')
 f.box(x+20,356,586,78,'ACT / 地址选择',asel+'；'+wsel,'comb')
 f.arrow(x+313,434,x+313,467)
 f.box(x+20,469,586,73,'issue 与输入所有权',iss,'comb')
 f.arrow(x+313,542,x+313,575)
 f.box(x+20,577,586,73,'Macro 输入边界',inp)
 f.box(x+20,673,586,73,'在途事务',ret)
 for k,note in enumerate(notes):f.text(x+20,786+31*k,note,'small')
f.text(40,934,'配置随数据推进：51 bit cfg = split + Macro enable + OC mask + last_phase + accum_mode；切换前端任务不会改写旧事务的解释。','body')
f.text(40,974,'最终发布：A3 在 C141 写 tmp / C142 采样；A4 在 C145 写 tmp / C146 采样。C146 可同时接收不兼容 B1 cmd。','body')
f.text(40,1014,'本图为采样沿快照；写入后的状态属于该沿之后。数值与完整握手见实测交接图和 timing_data CSV。','small')
f.save('Cluster_Pipeline_A3_A4.svg')
for p in D.glob('Cluster_*.svg'):ET.parse(p)
print('Updated three related SVG figures')
