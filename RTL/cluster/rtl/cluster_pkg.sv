`timescale 1ns / 1ps
package cluster_pkg;
  // Independent batch configuration; not part of the compute descriptor.
  typedef struct packed {
    logic conv_mode;  // Convolution: one enabled 4-OC reduction group
    logic requant_mode;  // 0: shared entry 0; 1: entry c corresponds to OC c
    logic [127:0] requant_multiplier;  // INT32 entry c: [32*c+:32]
    logic [39:0] requant_shift;  // INT10 entry c: [10*c+:10], -31..31
    // Per-channel INT32 effective zero point supplied by the parameter
    // producer, including input-offset compensation. mode controls scale only.
    logic [127:0] requant_zp;  // OC c: [32*c+:32], never compact masked OCs
  } requant_cfg_t;
  // Cluster descriptor: three eight-bit counts, total packed width 107 bits.
  typedef struct packed {
    // All counts are >=1. ws>1 selects WS, as>1 selects AS;
    // ws=as=1 is a single Context, with no cross-Context reuse.
    // WS reuses one Tile's weight for (ACT_bits/4)*ws_cnt internal
    // compute issues; ws_cnt still counts complete ACTs / Contexts.
    logic [7:0] os_cnt, ws_cnt, as_cnt;  // 1..255; WS/AS also obey capacity limits
    logic [6:0] reduce_split_mask;
    logic [7:0] macro_en_mask;
    logic [31:0] macro_oc_mask;
    logic [7:0] weight_cim_raddr;  // ONE address, broadcast to all eight macros
    logic [23:0] act_slot_sel;
    logic [2:0] precision;
    logic signed_en;
  } cluster_ctrl_t;

  function automatic int wbits(input int p);
    case (p)
      0, 1: return 2;
      2, 3, 4: return 4;
      5, 6: return 8;
      default: return 0;
    endcase
  endfunction
  function automatic int abits(input int p);
    case (p)
      0, 2: return 4;
      1, 3, 5: return 8;
      4, 6: return 16;
      default: return 0;
    endcase
  endfunction
  function automatic bit canonical(input logic [6:0] s);
    if (!s[0]) return s == 0;
    if (!s[1] && (s[3] || s[4])) return 0;
    if (!s[2] && (s[5] || s[6])) return 0;
    return 1;
  endfunction
  function automatic int first_leaf(input logic [6:0] s, input int m);
    if (!s[0]) return 0;
    if (!s[1+m/4]) return (m / 4) * 4;
    if (!s[3+m/2]) return (m / 2) * 2;
    return m;
  endfunction
  // Physical groups numbered left-to-right, retaining holes for idle groups.
  function automatic int group_of(input logic [6:0] s, input int m);
    int g;
    g = 0;
    // Fixed elaboration bound; m only controls the combinational predicate.
    for (int i = 1; i < 8; i++) if (i <= m && first_leaf(s, i) != first_leaf(s, i - 1)) g++;
    return g;
  endfunction
  // Convolution enables exactly one aligned 8/4/2-Macro reduction group.
  function automatic bit conv_group_legal(input cluster_ctrl_t cmd);
    int count, first;
    count = wbits(int'(cmd.precision));
    first = -1;
    if (count == 0 || !canonical(cmd.reduce_split_mask)) return 0;
    for (int m = 0; m < 8; m++) if (cmd.macro_en_mask[m] && first < 0) first = m;
    if (first < 0 || first % count != 0 || cmd.macro_en_mask != 8'(((1 << count) - 1) << first)) return 0;
    for (int m = 0; m < 8; m++) begin
      if (cmd.macro_en_mask[m] && first_leaf(cmd.reduce_split_mask, m) != first) return 0;
      if (!cmd.macro_en_mask[m] && first_leaf(cmd.reduce_split_mask, m) == first) return 0;
    end
    return 1;
  endfunction
  // Effective leaf contribution after all merge masks up to its endpoint.
  // Local Macro issue remains controlled by its own OC mask.
  function automatic bit merge_contributes(input logic [6:0] split, input logic [31:0] oc, input int m, c);
    if (!oc[4*m+c]) return 0;
    if (!split[3+m/2] && !oc[4*((m/2)*2)+c]) return 0;
    if (!split[1+m/4] && !oc[4*((m/4)*4)+c]) return 0;
    if (!split[0] && !oc[c]) return 0;
    return 1;
  endfunction
  function automatic longint signed number(input int unsigned raw, input int bits, input bit sign_en);
    longint signed n;
    n = raw & ((64'd1 << bits) - 1);
    if (sign_en && ((n >> (bits - 1)) & 1)) n -= 64'd1 << bits;
    return n;
  endfunction
endpackage
