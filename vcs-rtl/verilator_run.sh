#!/bin/bash
# Local Verilator flow for Anker TBs, mirroring Makefile's case handling but
# dumping FST (wave-mcp friendly) instead of FSDB. Requires conda env 'verilator'
# (verilator 5 + lz4-c + zlib): verilated.mk hardcodes the conda cross toolchain
# and a sysroot without lz4, so the build points CXX/LINK at the env explicitly.
#
#   ./verilator_run.sh build CASE=cluster_default       # elaborate + compile
#   ./verilator_run.sh run CASE=cluster_default         # prepare, build, run, check
#   ./verilator_run.sh run CASE=sram_rw +SRAM_RW_TEST   # plusargs pass through
#   ./verilator_run.sh run CASE=x +FST_FILE=out.fst     # FST name (default tb_Cluster_default.fst)
set -euo pipefail

ENV_DIR=${ENV_DIR:-/home/ubuntu/miniconda3/envs/verilator}
VLT="$ENV_DIR/bin/verilator"
R="$(cd "$(dirname "$0")" && pwd)"
MDIRBASE=${MDIR:-$R/../../.vltsimfst}

export PATH="$ENV_DIR/bin:$PATH"
MKVARS=(CXX="x86_64-conda-linux-gnu-c++ -I$ENV_DIR/include"
        LINK="x86_64-conda-linux-gnu-c++ -L$ENV_DIR/lib -Wl,-rpath,$ENV_DIR/lib"
        USER_LDLIBS="-L$ENV_DIR/lib -Wl,-rpath,$ENV_DIR/lib -llz4")

# TB / filelist per case family (mirrors Makefile TOP_* / FILE_*).
pick() { case $1 in
  cluster)                echo tb_Cluster verilog_file_cluster.f;;
  macro)                  echo tb_SingleMacro verilog_file_macro.f;;
  reduce)                 echo tb_ClusterReduceTree verilog_file_reduce.f;;
  requant)                echo tb_ClusterRequant verilog_file_requant.f;;
  gemm_os1_ws32_w8a16)    echo tb_Cluster_GEMM_OS1_WS32_W8A16 verilog_file_gemm_os1_ws32_w8a16.f;;
  gemm_os2_as4_w8a16)     echo tb_Cluster_GEMM_OS2_AS4_W8A16 verilog_file_gemm_os2_as4_w8a16.f;;
  gemm_w4a16_high_group)  echo tb_Cluster_GEMM_W4A16_HighGroup verilog_file_gemm_w4a16_high_group.f;;
  gemm_w2a8_high_group)   echo tb_Cluster_GEMM_W2A8_HighGroup verilog_file_gemm_w2a8_high_group.f;;
  gemm_w4a16_n6_tail)     echo tb_Cluster_GEMM_W4A16_N6_Tail verilog_file_gemm_w4a16_n6_tail.f;;
  gemm_w4a16_round_clip)  echo tb_Cluster_GEMM_W4A16_RoundClip verilog_file_gemm_w4a16_round_clip.f;;
  *) echo "unknown case family '$1'" >&2; return 1;;
esac; }

case_vars() {  # prints "TB|CASE_ARGS|CASE_PARAMS|CASE_DESCRIPTION" for a case, from cases.mk
  make -s -f cases.mk -f <(printf 'print:\n\t@echo "$(CASE_TB)|$(CASE_ARGS)|$(CASE_PARAMS)|$(CASE_DESCRIPTION)"\n') \
       print CASE="$1" RUN_DIR="$R/work/vlt_$1"
}

build_one() {  # $1 = case
  local c=${1:-cluster_default} top vfile args params mdir gargs=()
  local tb
  IFS='|' read -r tb args params _ <<< "$(case_vars "$c")"
  read -r top vfile <<< "$(pick "$tb")"
  mdir="$MDIRBASE/$c"
  for p in $params; do gargs+=("-G$p"); done  # CASE_PARAMS are NAME=VALUE pairs
  echo "[VLT] top=$top filelist=$vfile Mdir=$mdir case=$c"
  # --cc --exe --main (not --binary): let verilator only generate; the embedded
  # make would fail on the hardcoded toolchain, our explicit make below builds it.
  "$VLT" --cc --exe --main --timing --trace-fst -Wno-fatal --timescale 1ns/10ps \
    --top-module "$top" +define+SINGLE_MACRO_ASSERTIONS +define+CLUSTER_FST \
    -f "$vfile" --Mdir "$mdir" -o "${top}_vlt" "${gargs[@]}"
  make -C "$mdir" -f "V${top}.mk" -j"$(nproc)" "${MKVARS[@]}"
}

run_one() {
  local c="" plus=() a top vfile tb args params desc
  for a in "$@"; do case $a in CASE=*) c=${a#CASE=};; *) plus+=("$a");; esac; done
  c=${c:-cluster_default}
  local rundir="$R/work/vlt_$c"
  IFS='|' read -r tb args params desc <<< "$(case_vars "$c")"
  read -r top vfile <<< "$(pick "$tb")"
  mkdir -p "$rundir"
  (cd "$R" && python3 cases.py --prepare "$c" --directory "$rundir")
  [ -x "$MDIRBASE/$c/${top}_vlt" ] || build_one "$c"
  echo "[RUN] $c: $desc"
  ( cd "$rundir" && set +e
    "$MDIRBASE/$c/${top}_vlt" +DATA_DIR="$PWD/data" $args "${plus[@]}" 2>&1 | tee sim.log
    echo "${PIPESTATUS[0]}" > sim.exit )
  python3 cases.py --check "$c" --directory "$rundir"
  echo "[OK] $c  (work: $rundir, FST: $rundir/*.fst)"
}

cmd=${1:-}; shift || true
case $cmd in
  build) build_one "$(sed -n 's/^CASE=//p' <<< "${1:-}")" ;;
  run)   run_one "$@" ;;
  *) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
