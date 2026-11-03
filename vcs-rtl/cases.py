"""VCS case catalogue, deterministic data preparation and diagnostic checking."""
from pathlib import Path
import argparse
import importlib
import re
import sys

HERE = Path(__file__).resolve().parent
PY = HERE.parent / 'RTL/cluster/tb/py'
sys.path.insert(0, str(PY))
CASES = {}


def add(name, tb, description, marker, args='', params='', generator='', channel=False, negative=False):
    CASES[name] = dict(tb=tb, description=description, marker=marker, args=args,
                       params=params, generator=generator, channel=channel, negative=negative)


add('cluster_default', 'cluster', 'Raw arithmetic and standard timing', 'PASS configurations=', '', '', '', False, False)
add('sram_rw', 'cluster', 'Regular SRAM read write and OC masks', 'PASS sram_rw', '+SRAM_RW_TEST', '', '', False, False)
add('sram_write_compute_conflict', 'cluster', 'Reject regular SRAM write during active compute', 'CLUSTER_SRAM_PROTOCOL: regular access overlaps compute', '+SRAM_CONFLICT_WRITE_COMPUTE', '', '', False, True)
add('sram_compute_conflict', 'cluster', 'Reject regular SRAM read with compute Command', 'CLUSTER_SRAM_PROTOCOL: regular access overlaps compute', '+SRAM_CONFLICT_COMPUTE', '', '', False, True)
add('macro_gate0', 'macro', 'SingleMacro clock gating 0', 'PASS clock_gating=', '', 'CLOCK_GATING=0', '', False, False)
add('macro_gate1', 'macro', 'SingleMacro clock gating 1', 'PASS clock_gating=', '', 'CLOCK_GATING=1', '', False, False)
add('macro_negative_precision', 'macro', 'Reject precision', 'SM_PROTOCOL: illegal precision/phase', '+NEGATIVE=precision', '', '', False, True)
add('macro_negative_phase', 'macro', 'Reject phase', 'SM_PROTOCOL: illegal precision/phase', '+NEGATIVE=phase', '', '', False, True)
add('macro_negative_hold_invalid', 'macro', 'Reject hold invalid', 'SM_PROTOCOL: reuse invalid hold', '+NEGATIVE=hold_invalid', '', '', False, True)
add('macro_negative_uninitialized', 'macro', 'Reject uninitialized', 'SM_PROTOCOL: read uninitialized row', '+NEGATIVE=uninitialized', '', '', False, True)
add('macro_negative_masked_uninitialized', 'macro', 'Reject masked uninitialized', 'SM_PROTOCOL: read uninitialized row', '+NEGATIVE=masked_uninitialized', '', '', False, True)
add('macro_negative_masked_uninitialized_reuse', 'macro', 'Reject masked uninitialized reuse', 'SM_PROTOCOL: read uninitialized row', '+NEGATIVE=masked_uninitialized_reuse', '', '', False, True)
add('macro_negative_hold_address', 'macro', 'Reject hold address', 'SM_PROTOCOL: reuse address mismatch', '+NEGATIVE=hold_address', '', '', False, True)
add('macro_negative_hold_address_pending', 'macro', 'Reject hold address pending', 'SM_PROTOCOL: reuse address mismatch', '+NEGATIVE=hold_address_pending', '', '', False, True)
add('macro_negative_unknown_write', 'macro', 'Reject unknown write', 'SM_PROTOCOL: unknown write input', '+NEGATIVE=unknown_write', '', '', False, True)
add('macro_negative_unknown_activation', 'macro', 'Reject unknown activation', 'SM_PROTOCOL: unknown compute input', '+NEGATIVE=unknown_activation', '', '', False, True)
add('macro_negative_unknown_control', 'macro', 'Reject unknown control', 'SM_PROTOCOL: unknown compute input', '+NEGATIVE=unknown_control', '', '', False, True)
add('macro_negative_read_write', 'macro', 'Reject read write', 'SM_PROTOCOL: simultaneous read/write', '+NEGATIVE=read_write', '', '', False, True)
add('macro_negative_write_busy', 'macro', 'Reject write busy', 'SM_PROTOCOL: write before pipeline drain', '+NEGATIVE=write_busy', '', '', False, True)
add('macro_negative_hold_after_write', 'macro', 'Reject hold after write', 'SM_PROTOCOL: reuse invalid hold', '+NEGATIVE=hold_after_write', '', '', False, True)
add('macro_negative_hold_after_reset', 'macro', 'Reject hold after reset', 'SM_PROTOCOL: reuse invalid hold', '+NEGATIVE=hold_after_reset', '', '', False, True)
add('os_count_limit', 'cluster', 'os count limit', 'PASS os_count_limit cases=36', '+OS_COUNT_LIMIT_TEST', '', '', False, False)
add('oc_merge', 'cluster', 'oc merge', 'PASS oc_merge_leftmost cases=288', '+OC_MERGE_TEST', '', '', False, False)
add('act_buffer', 'cluster', 'act buffer', 'PASS act_buffer_capacity cases=280', '+ACT_BUFFER_TEST', '', '', False, False)
add('full_act', 'cluster', 'full act', 'PASS full_act_4096 cases=12', '+FULL_ACT_TEST', '', '', False, False)
add('mixed_context', 'cluster', 'mixed context', 'PASS mixed_context cases=24', '+MIXED_CONTEXT_TEST', '', '', False, False)
add('input_overlap', 'cluster', 'input overlap', 'PASS input_overlap cases=168', '+INPUT_OVERLAP_TEST', '', '', False, False)
add('context_stress', 'cluster', 'context stress', 'PASS context_stress cases=224', '+CONTEXT_STRESS_TEST', '', '', False, False)
add('as17_p0_s0_os1', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=1 +CAPACITY_PRECISION=0 +CAPACITY_SIGN=0', '', '', False, True)
add('as17_p0_s0_os2', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=2 +CAPACITY_PRECISION=0 +CAPACITY_SIGN=0', '', '', False, True)
add('as17_p0_s1_os1', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=1 +CAPACITY_PRECISION=0 +CAPACITY_SIGN=1', '', '', False, True)
add('as17_p0_s1_os2', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=2 +CAPACITY_PRECISION=0 +CAPACITY_SIGN=1', '', '', False, True)
add('as17_p1_s0_os1', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=1 +CAPACITY_PRECISION=1 +CAPACITY_SIGN=0', '', '', False, True)
add('as17_p1_s0_os2', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=2 +CAPACITY_PRECISION=1 +CAPACITY_SIGN=0', '', '', False, True)
add('as17_p1_s1_os1', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=1 +CAPACITY_PRECISION=1 +CAPACITY_SIGN=1', '', '', False, True)
add('as17_p1_s1_os2', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=2 +CAPACITY_PRECISION=1 +CAPACITY_SIGN=1', '', '', False, True)
add('as17_p2_s0_os1', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=1 +CAPACITY_PRECISION=2 +CAPACITY_SIGN=0', '', '', False, True)
add('as17_p2_s0_os2', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=2 +CAPACITY_PRECISION=2 +CAPACITY_SIGN=0', '', '', False, True)
add('as17_p2_s1_os1', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=1 +CAPACITY_PRECISION=2 +CAPACITY_SIGN=1', '', '', False, True)
add('as17_p2_s1_os2', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=2 +CAPACITY_PRECISION=2 +CAPACITY_SIGN=1', '', '', False, True)
add('as17_p3_s0_os1', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=1 +CAPACITY_PRECISION=3 +CAPACITY_SIGN=0', '', '', False, True)
add('as17_p3_s0_os2', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=2 +CAPACITY_PRECISION=3 +CAPACITY_SIGN=0', '', '', False, True)
add('as17_p3_s1_os1', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=1 +CAPACITY_PRECISION=3 +CAPACITY_SIGN=1', '', '', False, True)
add('as17_p3_s1_os2', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=2 +CAPACITY_PRECISION=3 +CAPACITY_SIGN=1', '', '', False, True)
add('as17_p4_s0_os1', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=1 +CAPACITY_PRECISION=4 +CAPACITY_SIGN=0', '', '', False, True)
add('as17_p4_s0_os2', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=2 +CAPACITY_PRECISION=4 +CAPACITY_SIGN=0', '', '', False, True)
add('as17_p4_s1_os1', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=1 +CAPACITY_PRECISION=4 +CAPACITY_SIGN=1', '', '', False, True)
add('as17_p4_s1_os2', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=2 +CAPACITY_PRECISION=4 +CAPACITY_SIGN=1', '', '', False, True)
add('as17_p5_s0_os1', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=1 +CAPACITY_PRECISION=5 +CAPACITY_SIGN=0', '', '', False, True)
add('as17_p5_s0_os2', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=2 +CAPACITY_PRECISION=5 +CAPACITY_SIGN=0', '', '', False, True)
add('as17_p5_s1_os1', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=1 +CAPACITY_PRECISION=5 +CAPACITY_SIGN=1', '', '', False, True)
add('as17_p5_s1_os2', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=2 +CAPACITY_PRECISION=5 +CAPACITY_SIGN=1', '', '', False, True)
add('as17_p6_s0_os1', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=1 +CAPACITY_PRECISION=6 +CAPACITY_SIGN=0', '', '', False, True)
add('as17_p6_s0_os2', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=2 +CAPACITY_PRECISION=6 +CAPACITY_SIGN=0', '', '', False, True)
add('as17_p6_s1_os1', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=1 +CAPACITY_PRECISION=6 +CAPACITY_SIGN=1', '', '', False, True)
add('as17_p6_s1_os2', 'cluster', 'Reject AS17 fixed-slot capacity', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=17 +CAPACITY_OS=2 +CAPACITY_PRECISION=6 +CAPACITY_SIGN=1', '', '', False, True)
add('reduce_tree', 'reduce', 'All reduction trees and clock gating', 'PASS reduce_clock_gating cases=208', '', '', '', False, False)
add('zero_count_0', 'cluster', 'Reject zero count field 0', 'CLUSTER_COUNT_RANGE: counts must be 1..511', '+ZERO_COUNT=0', '', '', False, True)
add('zero_count_1', 'cluster', 'Reject zero count field 1', 'CLUSTER_COUNT_RANGE: counts must be 1..511', '+ZERO_COUNT=1', '', '', False, True)
add('zero_count_2', 'cluster', 'Reject zero count field 2', 'CLUSTER_COUNT_RANGE: counts must be 1..511', '+ZERO_COUNT=2', '', '', False, True)
add('context_capacity_p0_s0', 'cluster', 'Reject AS64 with OS2 and Psum depth16', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_PRECISION=0 +CAPACITY_SIGN=0', '', '', False, True)
add('context_capacity_p0_s1', 'cluster', 'Reject AS64 with OS2 and Psum depth16', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_PRECISION=0 +CAPACITY_SIGN=1', '', '', False, True)
add('context_capacity_p1_s0', 'cluster', 'Reject AS64 with OS2 and Psum depth16', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_PRECISION=1 +CAPACITY_SIGN=0', '', '', False, True)
add('context_capacity_p1_s1', 'cluster', 'Reject AS64 with OS2 and Psum depth16', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_PRECISION=1 +CAPACITY_SIGN=1', '', '', False, True)
add('context_capacity_p2_s0', 'cluster', 'Reject AS64 with OS2 and Psum depth16', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_PRECISION=2 +CAPACITY_SIGN=0', '', '', False, True)
add('context_capacity_p2_s1', 'cluster', 'Reject AS64 with OS2 and Psum depth16', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_PRECISION=2 +CAPACITY_SIGN=1', '', '', False, True)
add('context_capacity_p3_s0', 'cluster', 'Reject AS64 with OS2 and Psum depth16', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_PRECISION=3 +CAPACITY_SIGN=0', '', '', False, True)
add('context_capacity_p3_s1', 'cluster', 'Reject AS64 with OS2 and Psum depth16', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_PRECISION=3 +CAPACITY_SIGN=1', '', '', False, True)
add('context_capacity_p4_s0', 'cluster', 'Reject AS64 with OS2 and Psum depth16', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_PRECISION=4 +CAPACITY_SIGN=0', '', '', False, True)
add('context_capacity_p4_s1', 'cluster', 'Reject AS64 with OS2 and Psum depth16', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_PRECISION=4 +CAPACITY_SIGN=1', '', '', False, True)
add('context_capacity_p5_s0', 'cluster', 'Reject AS64 with OS2 and Psum depth16', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_PRECISION=5 +CAPACITY_SIGN=0', '', '', False, True)
add('context_capacity_p5_s1', 'cluster', 'Reject AS64 with OS2 and Psum depth16', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_PRECISION=5 +CAPACITY_SIGN=1', '', '', False, True)
add('context_capacity_p6_s0', 'cluster', 'Reject AS64 with OS2 and Psum depth16', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_PRECISION=6 +CAPACITY_SIGN=0', '', '', False, True)
add('context_capacity_p6_s1', 'cluster', 'Reject AS64 with OS2 and Psum depth16', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_PRECISION=6 +CAPACITY_SIGN=1', '', '', False, True)
add('address_capacity_s0', 'cluster', 'Reject AS16 address capacity', 'CLUSTER_CONTEXT_CAPACITY: weight address depth exceeded', '+CONTEXT_CAPACITY_TEST +ADDRESS_CAPACITY_TEST +CAPACITY_PRECISION=6 +CAPACITY_SIGN=0', 'WGT_RADDR_BUFFER_DEPTH=8', '', False, True)
add('address_capacity_s1', 'cluster', 'Reject AS16 address capacity', 'CLUSTER_CONTEXT_CAPACITY: weight address depth exceeded', '+CONTEXT_CAPACITY_TEST +ADDRESS_CAPACITY_TEST +CAPACITY_PRECISION=6 +CAPACITY_SIGN=1', 'WGT_RADDR_BUFFER_DEPTH=8', '', False, True)
add('metadata_capacity_s0', 'cluster', 'Reject AS16 metadata capacity', 'CLUSTER_CONTEXT_CAPACITY: context metadata exceeded', '+CONTEXT_CAPACITY_TEST +METADATA_CAPACITY_TEST +CAPACITY_PRECISION=6 +CAPACITY_SIGN=0', 'MAX_CONTEXTS=8', '', False, True)
add('metadata_capacity_s1', 'cluster', 'Reject AS16 metadata capacity', 'CLUSTER_CONTEXT_CAPACITY: context metadata exceeded', '+CONTEXT_CAPACITY_TEST +METADATA_CAPACITY_TEST +CAPACITY_PRECISION=6 +CAPACITY_SIGN=1', 'MAX_CONTEXTS=8', '', False, True)
add('gemm_os1_ws1_as8_w8a16_raw', 'gemm_os1_ws1_as8_w8a16', 'Raw signed32 GEMM as8', 'PASS gemm_os1_as8_w8a16 M=8 K=256 N=32', '', '', 'as8', False, False)
add('gemm_os1_ws32_as1_w8a16_raw', 'gemm_os1_ws32_w8a16', 'Raw signed32 GEMM ws32', 'PASS gemm_os1_ws32_w8a16 M=32 K=128 N=16', '', '', 'ws32', False, False)
add('gemm_os2_ws1_as4_w8a16_raw', 'gemm_os2_as4_w8a16', 'Raw signed32 GEMM as4', 'PASS gemm_os2_as4_w8a16 M=32 K=512 N=16', '', '', 'as4', False, False)
add('gemm_os1_ws8_as1_w4a16_high_group_raw', 'gemm_w4a16_high_group', 'Raw signed32 GEMM w4a16_high_group', 'PASS gemm_w4a16_high_group', '', '', 'w4a16_high_group', False, False)
add('gemm_os1_ws8_as1_w2a8_high_group_raw', 'gemm_w2a8_high_group', 'Raw signed32 GEMM w2a8_high_group', 'PASS gemm_w2a8_high_group', '', '', 'w2a8_high_group', False, False)
add('gemm_os1_ws8_as1_w4a16_n6_tail_raw', 'gemm_w4a16_n6_tail', 'Raw signed32 GEMM w4a16_n6_tail', 'PASS gemm_w4a16_n6_tail', '', '', 'w4a16_n6_tail', False, False)
add('gemm_os1_ws12_as1_w4a16_round_clip_raw', 'gemm_w4a16_round_clip', 'Raw signed32 GEMM w4a16_round_clip', 'PASS gemm_w4a16_round_clip', '', '', 'w4a16_round_clip', False, False)
add('gate_equiv_default', 'cluster', 'Gated/ungated Cluster same-edge comparison: default', 'PASS configurations=', '', 'CHECK_GATE_EQUIVALENCE=1', '', False, False)
add('gate_equiv_context_stress', 'cluster', 'Gated/ungated Cluster same-edge comparison: context_stress', 'PASS context_stress cases=224', '+CONTEXT_STRESS_TEST', 'CHECK_GATE_EQUIVALENCE=1', '', False, False)
add('gate_equiv_input_overlap', 'cluster', 'Gated/ungated Cluster same-edge comparison: input_overlap', 'PASS input_overlap cases=168', '+INPUT_OVERLAP_TEST', 'CHECK_GATE_EQUIVALENCE=1', '', False, False)
add('gate_equiv_sram', 'cluster', 'Gated/ungated Cluster same-edge comparison: sram', 'PASS sram_rw', '+SRAM_RW_TEST', 'CHECK_GATE_EQUIVALENCE=1', '', False, False)
add('as64_p0_s0_os1', 'cluster', 'Reject AS64 with OS1', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=64 +CAPACITY_OS=1 +CAPACITY_PRECISION=0 +CAPACITY_SIGN=0', '', '', False, True)
add('as64_p0_s1_os1', 'cluster', 'Reject AS64 with OS1', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=64 +CAPACITY_OS=1 +CAPACITY_PRECISION=0 +CAPACITY_SIGN=1', '', '', False, True)
add('as64_p1_s0_os1', 'cluster', 'Reject AS64 with OS1', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=64 +CAPACITY_OS=1 +CAPACITY_PRECISION=1 +CAPACITY_SIGN=0', '', '', False, True)
add('as64_p1_s1_os1', 'cluster', 'Reject AS64 with OS1', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=64 +CAPACITY_OS=1 +CAPACITY_PRECISION=1 +CAPACITY_SIGN=1', '', '', False, True)
add('as64_p2_s0_os1', 'cluster', 'Reject AS64 with OS1', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=64 +CAPACITY_OS=1 +CAPACITY_PRECISION=2 +CAPACITY_SIGN=0', '', '', False, True)
add('as64_p2_s1_os1', 'cluster', 'Reject AS64 with OS1', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=64 +CAPACITY_OS=1 +CAPACITY_PRECISION=2 +CAPACITY_SIGN=1', '', '', False, True)
add('as64_p3_s0_os1', 'cluster', 'Reject AS64 with OS1', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=64 +CAPACITY_OS=1 +CAPACITY_PRECISION=3 +CAPACITY_SIGN=0', '', '', False, True)
add('as64_p3_s1_os1', 'cluster', 'Reject AS64 with OS1', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=64 +CAPACITY_OS=1 +CAPACITY_PRECISION=3 +CAPACITY_SIGN=1', '', '', False, True)
add('as64_p4_s0_os1', 'cluster', 'Reject AS64 with OS1', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=64 +CAPACITY_OS=1 +CAPACITY_PRECISION=4 +CAPACITY_SIGN=0', '', '', False, True)
add('as64_p4_s1_os1', 'cluster', 'Reject AS64 with OS1', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=64 +CAPACITY_OS=1 +CAPACITY_PRECISION=4 +CAPACITY_SIGN=1', '', '', False, True)
add('as64_p5_s0_os1', 'cluster', 'Reject AS64 with OS1', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=64 +CAPACITY_OS=1 +CAPACITY_PRECISION=5 +CAPACITY_SIGN=0', '', '', False, True)
add('as64_p5_s1_os1', 'cluster', 'Reject AS64 with OS1', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=64 +CAPACITY_OS=1 +CAPACITY_PRECISION=5 +CAPACITY_SIGN=1', '', '', False, True)
add('as64_p6_s0_os1', 'cluster', 'Reject AS64 with OS1', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=64 +CAPACITY_OS=1 +CAPACITY_PRECISION=6 +CAPACITY_SIGN=0', '', '', False, True)
add('as64_p6_s1_os1', 'cluster', 'Reject AS64 with OS1', 'CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth', '+CONTEXT_CAPACITY_TEST +CAPACITY_COUNT=64 +CAPACITY_OS=1 +CAPACITY_PRECISION=6 +CAPACITY_SIGN=1', '', '', False, True)
add('sram_response', 'cluster', 'Synchronous read valid and sampled Macro response', 'PASS sram_response reads=32', '+SRAM_RESPONSE_TEST', '', '', False, False)
add('gate_equiv_sram_response', 'cluster', 'Read response gated/ungated comparison', 'PASS sram_response reads=32', '+SRAM_RESPONSE_TEST', 'CHECK_GATE_EQUIVALENCE=1', '', False, False)
add('empty_batch', 'cluster', 'Empty batch followed immediately by nonempty raw batch', 'PASS empty_batch cases=7', '+EMPTY_BATCH_TEST', '', '', False, False)
add('gate_equiv_empty_batch', 'cluster', 'Empty raw batch gated/ungated comparison', 'PASS empty_batch cases=7', '+EMPTY_BATCH_TEST', 'CHECK_GATE_EQUIVALENCE=1', '', False, False)


def write_makefile():
    lines = ['# Generated by cases.py --write; edit the catalogue in cases.py.',
             'VALID_CASES := '+' '.join(CASES)]
    for name, c in CASES.items():
        lines.append(f'ifeq ($(CASE),{name})')
        for field in ('tb', 'description', 'args', 'params'):
            assignment='=' if field=='args' else ':='
            lines.append(f'CASE_{field.upper()} {assignment} {c[field]}'.rstrip())
        if c['generator']:
            lines.append('CASE_ARGS += +GEMM_DATA_DIR=$(abspath $(RUN_DIR))/data')
            if c['generator'] not in ('ws32','as4','as8'):
                lines.append('CASE_ARGS += +GEMM_CASE_NAME=$(CASE)')
        lines.append('endif')
    (HERE/'cases.mk').write_text('\n'.join(lines)+'\n', encoding='utf-8')


def prepare(name, directory):
    directory.mkdir(parents=True, exist_ok=True)
    data=directory/'data';data.mkdir(exist_ok=True)
    c=CASES[name];gen=c['generator']
    if gen in ('ws32', 'as4', 'as8'):
        module = {'ws32':'gemm_os1_ws32_w8a16_vectors', 'as4':'gemm_os2_as4_w8a16_vectors',
                  'as8':'gemm_os1_ws1_as8_w8a16_vectors'}[gen]
        mod=importlib.import_module(module)
        mod.generate(data, per_channel=c['channel'])
    elif gen:
        importlib.import_module('gemm_scenario_vectors').generate(data, gen, gen=='w4a16_round_clip')
    print(f'[CASE] name={name} description={c["description"]}')


def check(name, directory):
    c=CASES[name];log=(directory/'sim.log').read_text(encoding='utf-8', errors='replace')
    exit_status=(directory/'sim.exit').read_text().strip()
    if c['marker'] not in log:raise SystemExit('FAIL: missing expected marker: '+c['marker'])
    lines=log.splitlines()
    diagnostics=[i for i,line in enumerate(lines) if re.search(r'^\s*(?:#\s*)?(?:\*\*\s*)?(?:Fatal:|Fatal-|Error-|Error:|FATAL\b)',line,re.I)]
    # A negative suite succeeds only on its named protocol diagnostic. Other
    # simulator failures must never be mistaken for an expected rejection.
    if c['negative']:
        if exit_status not in ('0','1'):raise SystemExit('FAIL: abnormal simulator exit '+exit_status)
        windows=['\n'.join(lines[i:i+4]) for i in diagnostics]
        if len(windows)!=1 or c['marker'] not in windows[0]:
            raise SystemExit('FAIL: expected marker was not a fatal diagnostic')
        if not re.search(r'Fatal',lines[diagnostics[0]],re.I):raise SystemExit('FAIL: expected a fatal, not a simulator error')
    elif diagnostics:raise SystemExit('FAIL: unexpected diagnostics: '+'\n'.join(lines[i] for i in diagnostics))
    if not c['negative'] and exit_status!='0':
        raise SystemExit('FAIL: simulator returned nonzero status')
    if name.startswith('gate_equiv_') and 'PASS cluster_gate_equivalence cycles=' not in log:
        raise SystemExit('FAIL: missing whole-Cluster gate equivalence marker')
    if not c['negative']:
        if c['generator']:
            import csv
            def matrix(path):
                rows=list(csv.DictReader(path.open(encoding='utf-8')))
                result={(int(r['m']),int(r['n'])):int(r['raw']) for r in rows}
                if len(rows)!=len(result):raise SystemExit('FAIL: duplicate raw matrix coordinates')
                return result
            golden=matrix(directory/'data/matrix_golden.csv')
            actual=matrix(directory/'data/gemm_observed_matrix.csv')
            if actual!=golden:raise SystemExit('FAIL: raw GEMM matrix mismatch')
            print(f'PASS raw GEMM comparison: {len(actual)} signed32 elements')
        if name=='cluster_default':
            import subprocess
            subprocess.run([sys.executable,str(PY/'verify_manifest.py'),str(directory/'data/split_cases.csv')],check=True)
    print('PASS VCS case '+name+(' expected rejection' if c['negative'] else ''))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--write', action='store_true');p.add_argument('--list', action='store_true')
    p.add_argument('--prepare', choices=CASES);p.add_argument('--check', choices=CASES)
    p.add_argument('--directory', type=Path)
    args=p.parse_args()
    if args.write:write_makefile()
    if args.list:
        for name,c in CASES.items():print(f'{name}: {c["description"]}'+(' [expected fatal]' if c['negative'] else ''))
    if args.prepare or args.check:
        if args.directory is None:p.error('--directory is required')
        (prepare if args.prepare else check)(args.prepare or args.check,args.directory.resolve())
