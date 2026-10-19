# Anker-CIM-Block VCS RTL 仿真流程（独立于 ModelSim/Verilator 流程）
# 用法（在本目录下执行）：
#   make com               # 编译（默认 TB=cluster，顶层 tb_Cluster）
#   make sim               # 运行仿真，日志 work/${OUTPUT}.log
#   make check             # 扫描日志 PASS/Fatal，并核对 split_cases.csv（仅 cluster）
#   make vcd               # 用 UCLI 重跑仿真并 dump 波形 work/${OUTPUT}.vcd
#   make debug             # 用 Verdi 打开 kdb 调试数据库
#   make clean
#   make com sim TB=macro  # 切换 macro 级（顶层 tb_SingleMacro）
#   make sim PVALUE=-pvalue+tb_Cluster.OS_TILES=2   # 运行期覆盖 TB 参数
.PHONY: com sim debug clean vcd check

# ---------------- 目标选择 ----------------
TB       ?= cluster
ifeq ($(TB),macro)
TOP        = tb_SingleMacro
V_FILE     = ./verilog_file_macro.f
else
TOP        = tb_Cluster
V_FILE     = ./verilog_file_pl.f
endif

OUTPUT   = ${TOP}_2026
WORK_DIR = ./work

# 本仓库为纯 RTL，无需工艺库/宏模型；后续做门级或模拟宏仿真时，把 -v <cell>.v 追加到这里
LIB_LIST =

# SINGLE_MACRO_ASSERTIONS：使能 SingleMacro.sv 内的协议断言
ALL_DEFINE = +define+SINGLE_MACRO_ASSERTIONS

VCS = vcs 	-sverilog +v2k                \
          	+libext+.v+.sv                \
	    	-debug_access+all             \
	    	-debug_region+cell            \
	    	-kdb                          \
	    	+warn=noRWSI                  \
	    	+vcs+flush+all                \
	    	-Mdir=${WORK_DIR}/csrc        \
	    	-o ${WORK_DIR}/${OUTPUT}      \
	    	-timescale=1ns/10ps           \
	    	-l ${WORK_DIR}/compile_${OUTPUT}.log  \
	    	-Mupdate                      \
	    	-full64                       \
	    	+lint=TFIPC-L                 \
	    	+neg_tchk                     \
	    	-negdelay                     \
		${LIB_LIST}

SIM = ./${OUTPUT} -l ${OUTPUT}.log ${PVALUE}

com:
	mkdir -p ${WORK_DIR}
	${VCS} -f ${V_FILE} ${ALL_DEFINE}

sim:
	cd ${WORK_DIR}; ${SIM}

# 重新仿真并 dump 波形：编译已带 -debug_access+all，运行期经 UCLI dump；
# 需要调整层级改 -depth，需要 VPD/FSDB 就换 -file 扩展名（或加 -type）
vcd:
	cd ${WORK_DIR}; ./${OUTPUT} -ucli -do "dump -add ${TOP} -depth 10 -file ${OUTPUT}.vcd; run; quit" -l vcd_${OUTPUT}.log

debug:
	cd ${WORK_DIR}; verdi -dbdir ${OUTPUT}.kdb.elab &

ifeq ($(TB),cluster)
check:
	grep -q "PASS configurations=" ${WORK_DIR}/${OUTPUT}.log
	! grep -qiE "fatal|error-" ${WORK_DIR}/${OUTPUT}.log
	python3 ../RTL/Anker-CIM-Block/cluster/cluster_tb/verify_manifest.py ${WORK_DIR}/split_cases.csv
else
check:
	grep -q "PASS clock_gating=" ${WORK_DIR}/${OUTPUT}.log
	! grep -qiE "fatal|error-" ${WORK_DIR}/${OUTPUT}.log
endif

clean:
	rm -rf ${WORK_DIR} *.log *.vpd *.vcd *.fsdb *.key simv* csrc *.daidir DVEfiles
