`timescale 1ns/1ps
package cluster_tb_pkg;
  // Cluster descriptor: three 16-bit counts, total packed width 131 bits.
  typedef struct packed {
    // All counts are >=1. ws>1 selects WS, as>1 selects AS;
    // ws=as=1 is a single Context, with no cross-Context reuse.
    // WS reuses one Tile's weight for (ACT_bits/4)*ws_cnt internal
    // compute issues; ws_cnt still counts complete ACTs / Contexts.
    logic [15:0] os_cnt, ws_cnt, as_cnt;
    logic [6:0] reduce_split_mask;
    logic [7:0] macro_en_mask;
    logic [31:0] macro_oc_mask;
    logic [7:0] weight_cim_raddr; // ONE address, broadcast to all eight macros
    logic [23:0] act_slot_sel;
    logic [2:0] precision;
    logic signed_en;
  } cluster_ctrl_t;

  function automatic int wbits(input int p);
    case(p) 0,1: return 2; 2,3,4: return 4; 5,6: return 8;
      default: return 0; endcase
  endfunction
  function automatic int abits(input int p);
    case(p) 0,2: return 4; 1,3,5: return 8; 4,6: return 16;
      default: return 0; endcase
  endfunction
  function automatic bit canonical(input logic [6:0] s);
    if (!s[0]) return s == 0;
    if (!s[1] && (s[3] || s[4])) return 0;
    if (!s[2] && (s[5] || s[6])) return 0;
    return 1;
  endfunction
  function automatic int first_leaf(input logic [6:0] s, input int m);
    if (!s[0]) return 0;
    if (!s[1+m/4]) return (m/4)*4;
    if (!s[3+m/2]) return (m/2)*2;
    return m;
  endfunction
  // Physical groups numbered left-to-right, retaining holes for idle groups.
  function automatic int group_of(input logic [6:0] s, input int m);
    int g;
    g=0;
    // Fixed elaboration bound; m only controls the combinational predicate.
    for (int i=1;i<8;i++)
      if (i<=m && first_leaf(s,i)!=first_leaf(s,i-1)) g++;
    return g;
  endfunction
  function automatic longint signed number(
      input int unsigned raw, input int bits, input bit sign_en);
    longint signed n;
    n=raw & ((64'd1<<bits)-1);
    if (sign_en && ((n>>(bits-1))&1)) n-=64'd1<<bits;
    return n;
  endfunction
endpackage
