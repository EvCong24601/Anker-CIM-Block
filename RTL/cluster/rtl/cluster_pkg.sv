`timescale 1ns / 1ps
package cluster_pkg;
  // Cluster descriptor: three nine-bit counts, total packed width 110 bits.
  typedef struct packed {
    // All counts are >=1. ws>1 selects WS, as>1 selects AS;
    // ws=as=1 is a single Context, with no cross-Context reuse.
    // WS reuses one Tile's weight for (ACT_bits/4)*cim_ws_cnt internal
    // compute issues; cim_ws_cnt still counts complete ACTs / Contexts.
    logic [8:0] cim_os_cnt, cim_ws_cnt, cim_as_cnt;  // 1..511; WS/AS also obey capacity limits
    logic [6:0] cim_reduce_split_mask;
    logic [7:0] cim_macro_en_mask;
    logic [31:0] cim_macro_oc_mask;
    logic [7:0] cim_weight_raddr;  // ONE address, broadcast to all eight macros
    logic [23:0] cim_act_slot_sel;
    logic [2:0] cim_precision;
    logic cim_signed_en;
  } cluster_ctrl_t;

endpackage
