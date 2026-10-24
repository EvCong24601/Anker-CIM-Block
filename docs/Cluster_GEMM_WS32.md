# 单 Cluster W8A16 OS1 WS32 GEMM

X[32,128]×W[128,16]使用一个Cluster，OS/WS/AS=1/32/1。按统一四通道Requant限制，分四批N4完成N16；不再使用两组并行N8。每批重放全部32行ACT，输出512个raw和512个INT8。支持per-tensor weight和per-channel weight两个版本。

## 权重与输入

W8开启八个Macro全归约K256/N4。逻辑K=128，Macro0～3分别存K0～31、32～63、64～95、96～127；Macro4～7存全零，ACT高128个K位置也补零。四个地址0x40、0x41、0x42、0x43分别保存N0～3、4～7、8～11、12～15。

每个地址占八个Macro的128B行，共1KiB；四个地址共4KiB，常规端口共32次写入、32次读回。Macro m、OC c的byte j保存Wq[32*m+j,4*N_tile+c]，超出K128的权重为0。cim_macro_group=m/4，cim_bank_sel=m%4，cim_wmask=0。

descriptor：precision=6，signed_en=1，counts=1/32/1，reduce_split_mask=0，macro_en_mask=0xff，macro_oc_mask=0xffffffff，act_slot_sel=0xfac688。weight_cim_raddr在四批间切换0x40～0x43。

ACT每Plane为1024bit，低512bit承载Xq行的128个nibble，高512bit清零。A0与Command同拍输入，随后连续A1～A3；不在输入端减ACT_zp。内部分别在C1～C4发射，下一ACT包从C5开始，同包接收/发射重叠保持不变。

每批行m在C(5m)接受Command/A0，C(5m+9)发布4OC raw，C(5m+10)发布INT8。首末raw为C9/C164，首末INT8为C10/C165。根归约比旧的四Macro半树增加1T。每批32条Command、128次发射；全例128条Command、512次发射。每个Macro每批仅首次刷新weight Hold，其余127次复用。OS1绕过Psum历史，WS32不增加默认深度16。

## 两种weight量化

原始实数X/W由固定种子0x3212816生成；ACT始终为per-tensor signed A16非对称量化，weight为signed W8对称量化，W_zp=0，输出使用共用INT8 scale。

- 默认版本：整张W共享一个scale；requant_mode=0，四个OC共用第0项multiplier/shift。参数仍为ACT_zp=−9264、multiplier=4649、shift=−31。
- --per-channel版本：每个输出列n独立计算W_scale[n]=max(abs(W_real[:,n]))/127，分别量化该列；requant_mode=1、conv_mode=1。由X_scale×W_scale[n]/Y_scale生成每列的INT32 multiplier和INT10 shift，当前shift依次取−31、−30、−29、−28并重复。

两版输入补偿均已合入逐通道INT32 zp。每批仅送当前4列的zp，per-channel版再送同四列的multiplier/shift。参数c固定对应oc_mask中的OC c，屏蔽通道不压缩参数。

Python先算原始实数矩阵乘法，再校准量化参数；输出raw=Xq×Wq，以及q=clip(round(raw×effective_scale[n])+merged_zp[n])的精确整数golden。中心化与实数参考另存并报告误差，不作为RTL允许误差。per-channel weight会改变编码W、raw和INT8 golden，不能沿用per-tensor文件。

## 复现与文件

tb_Cluster_GEMM_OS1_WS32.sv共享两个版本的驱动、scoreboard和调度；以+PER_CHANNEL_SCALE选择per-channel weight数据。

- cluster_gemm_driver.svh：矩阵/参数读取、打包独立检查、32行权重写入读回、四批WS32驱动。
- cluster_gemm_scoreboard.svh：权重保持、Psum旁路、四OC输出和周期、512个raw/INT8及保持规则。
- cluster_gemm_regression.svh：四批调度、覆盖、完整输出矩阵。
- gemm_vectors.py：--per-channel开关；生成weight_channel_scales、requant_multiplier.hex、requant_shift.hex、requant_zp.hex、矩阵golden和输入计划。

仿真使用 [VCS case 入口](../vcs-rtl/README.md)，支持独立编译、数据生成、运行及结果检查。

仓库data/gemm_ws32/保存per-tensor数据，data/gemm_ws32_per_channel/保存per-channel数据；metadata及SHA256用于审阅和重现。
