# Run from vcs-rtl: make run CASE=gemm_os1_ws32_as1_w8a16_channel
.DEFAULT_GOAL := help
CASE ?=
TB ?= cluster
PYTHON ?= python3
WORK_DIR ?= work
RUN_DIR = $(WORK_DIR)/$(CASE_TAG)
include cases.mk
ifneq ($(strip $(CASE)),)
ifeq ($(filter $(CASE),$(VALID_CASES)),)
$(error Unknown CASE '$(CASE)'; run make list)
endif
override TB := $(CASE_TB)
endif
TOP_cluster := tb_Cluster
TOP_macro := tb_SingleMacro
TOP_reduce := tb_ClusterReduceTree
TOP_requant := tb_ClusterRequant
TOP_gemm_os1_ws32_w8a16 := tb_Cluster_GEMM_OS1_WS32_W8A16
TOP_gemm_os2_as4_w8a16 := tb_Cluster_GEMM_OS2_AS4_W8A16
TOP_gemm_os1_ws1_as8_w8a16 := tb_Cluster_GEMM_OS1_WS1_AS8_W8A16
TOP_gemm_w4a16_high_group := tb_Cluster_GEMM_W4A16_HighGroup
TOP_gemm_w2a8_high_group := tb_Cluster_GEMM_W2A8_HighGroup
TOP_gemm_w4a16_n6_tail := tb_Cluster_GEMM_W4A16_N6_Tail
TOP_gemm_w4a16_round_clip := tb_Cluster_GEMM_W4A16_RoundClip
TOP := $(TOP_$(TB))
ifeq ($(strip $(TOP)),)
$(error Unknown TB '$(TB)')
endif
FILE_cluster := verilog_file_cluster.f
FILE_macro := verilog_file_macro.f
FILE_reduce := verilog_file_reduce.f
FILE_requant := verilog_file_requant.f
FILE_gemm_os1_ws32_w8a16 := verilog_file_gemm_os1_ws32_w8a16.f
FILE_gemm_os2_as4_w8a16 := verilog_file_gemm_os2_as4_w8a16.f
FILE_gemm_os1_ws1_as8_w8a16 := verilog_file_gemm_os1_ws1_as8_w8a16.f
FILE_gemm_w4a16_high_group := verilog_file_gemm_w4a16_high_group.f
FILE_gemm_w2a8_high_group := verilog_file_gemm_w2a8_high_group.f
FILE_gemm_w4a16_n6_tail := verilog_file_gemm_w4a16_n6_tail.f
FILE_gemm_w4a16_round_clip := verilog_file_gemm_w4a16_round_clip.f
V_FILE := $(FILE_$(TB))
CASE_TAG ?= $(if $(CASE),$(CASE),$(TB)_custom)
OUTPUT ?= $(TOP)
FSDB_FILE ?= $(OUTPUT)_$(CASE_TAG).fsdb
PARAMETERS ?=
PVALUE ?=
LIB_LIST ?=
ALL_DEFINE ?= +define+SINGLE_MACRO_ASSERTIONS +define+CLUSTER_FSDB
CASE_PARAMETERS = $(foreach p,$(CASE_PARAMS),-pvalue+$(TOP).$(p))
VCS_FLAGS ?= -sverilog +v2k +libext+.v+.sv -full64 -timescale=1ns/10ps -debug_access+all -kdb +vcs+flush+all +lint=TFIPC-L

.PHONY: help list prepare com sim check run regression gemm-regression debug wave vcd clean sram requant-vectors gemm-vectors gemm-as-vectors gemm-channel-vectors gemm-as-channel-vectors
help:
	@echo 'make run CASE=gemm_os1_ws32_as1_w8a16_channel  # prepare, compile, simulate, check'
	@echo 'make list                      # all case descriptions'
	@echo 'make regression                # includes expected rejections'
	@echo 'make gemm-regression           # 13 positive GEMM variants'
	@echo 'See README.md for variables, file lists and FSDB naming.'
list:
	$(PYTHON) cases.py --list
prepare:
	mkdir -p $(RUN_DIR)/data
ifneq ($(strip $(CASE)),)
	$(PYTHON) cases.py --prepare $(CASE) --directory $(RUN_DIR)
endif
com: prepare
	vcs $(VCS_FLAGS) $(LIB_LIST) -top $(TOP) -f $(V_FILE) $(ALL_DEFINE) $(CASE_PARAMETERS) $(PARAMETERS) -Mdir=$(RUN_DIR)/csrc -o $(abspath $(RUN_DIR))/$(OUTPUT) -l $(RUN_DIR)/compile.log
sim: prepare
	@echo '[RUN] $(CASE_TAG): $(CASE_DESCRIPTION)'
	@cd $(RUN_DIR) && ./$(OUTPUT) -l sim.log +DATA_DIR=$(abspath $(RUN_DIR))/data $(CASE_ARGS) $(PVALUE) +FSDB_FILE=$(FSDB_FILE); status=$$?; echo $$status > sim.exit; exit $$status
# Keep stages sequential even when invoked with make -j.
# Expected rejections return a nonzero status on purpose, so the simulator stage is
# allowed to fail here and the check stage below decides whether that was expected.
run: com
	-$(MAKE) sim CASE=$(CASE) TB=$(TB)
	$(MAKE) check CASE=$(CASE) TB=$(TB)
check:
ifneq ($(strip $(CASE)),)
	$(PYTHON) cases.py --check $(CASE) --directory $(RUN_DIR)
else
	@test "$$(cat $(RUN_DIR)/sim.exit)" = 0
	@grep -q PASS $(RUN_DIR)/sim.log
	@! grep -qiE 'fatal|Error-' $(RUN_DIR)/sim.log
endif
regression:
	@set -e; for c in $(VALID_CASES); do $(MAKE) run CASE=$$c; done
gemm-regression:
	@set -e; for c in $(filter gemm_%,$(VALID_CASES)); do $(MAKE) run CASE=$$c; done
sram:
	$(MAKE) run CASE=sram_rw
wave:
	cd $(RUN_DIR) && verdi -ssf $(FSDB_FILE) &
debug:
	cd $(RUN_DIR) && verdi -dbdir $(OUTPUT).daidir &
vcd:
	cd $(RUN_DIR) && ./$(OUTPUT) $(CASE_ARGS) $(PVALUE) +DATA_DIR=$(abspath $(RUN_DIR))/data +FSDB_FILE=$(FSDB_FILE) -ucli -do 'dump -add $(TOP) -depth 10 -file $(OUTPUT)_$(CASE_TAG).vcd; run; quit' -l vcd.log
requant-vectors:
	$(MAKE) prepare CASE=requant_unit
gemm-vectors:
	$(MAKE) prepare CASE=gemm_os1_ws32_as1_w8a16_tensor
gemm-as-vectors:
	$(MAKE) prepare CASE=gemm_os2_ws1_as4_w8a16_tensor
gemm-channel-vectors:
	$(MAKE) prepare CASE=gemm_os1_ws32_as1_w8a16_channel
gemm-as-channel-vectors:
	$(MAKE) prepare CASE=gemm_os2_ws1_as4_w8a16_channel
clean:
	rm -rf -- ./work
