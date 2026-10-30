`timescale 1ns / 1ps
package cluster_pkg;
  // Independent batch configuration; not part of the compute descriptor.
  typedef struct packed {
    // Weight quantization: 0 = per-tensor, shared entry 0 and ZP in TB;
    // 1 = per-channel, entry c for OC c and ZP in RTL before saturation.
    logic conv_mode;
    logic [127:0] requant_multiplier;  // INT32 entry c: [32*c+:32]
    logic [39:0] requant_shift;  // INT10 entry c: [10*c+:10], -512..511
    // Per-channel INT32 effective zero point supplied by the parameter
    // producer, including input-offset compensation. Used only in mode=1;
    // mode=0 ignores this compatibility field and applies channel ZP in TB.
    logic [127:0] requant_zp;  // OC c: [32*c+:32], never compact masked OCs
  } requant_cfg_t;
  // Cluster descriptor: three eight-bit counts, total packed width 107 bits.
  typedef struct packed {
    // All counts are >=1. ws>1 selects WS, as>1 selects AS;
    // ws=as=1 is a single Context, with no cross-Context reuse.
    // WS reuses one Tile's weight for (ACT_bits/4)*cim_ws_cnt internal
    // compute issues; cim_ws_cnt still counts complete ACTs / Contexts.
    logic [7:0] cim_os_cnt, cim_ws_cnt, cim_as_cnt;  // 1..255; WS/AS also obey capacity limits
    logic [6:0] cim_reduce_split_mask;
    logic [7:0] cim_macro_en_mask;
    logic [31:0] cim_macro_oc_mask;
    logic [7:0] cim_weight_raddr;  // ONE address, broadcast to all eight macros
    logic [23:0] cim_act_slot_sel;
    logic [2:0] cim_precision;
    logic cim_signed_en;
  } cluster_ctrl_t;

endpackage
