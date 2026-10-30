// Include inside each consuming module after importing cluster_pkg.
// No include guard: each module needs its own function declarations.
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
  // Effective leaf contribution after all merge masks up to its endpoint.
  // Local Macro issue remains controlled by its own OC mask; this demand
  // also gates Macro result and child forwarding registers.
  function automatic bit merge_contributes(input logic [6:0] split, input logic [31:0] oc, input int m, input int c);
    if (!oc[4*m+c]) return 0;
    if (!split[3+m/2] && !oc[4*((m/2)*2)+c]) return 0;
    if (!split[1+m/4] && !oc[4*((m/4)*4)+c]) return 0;
    if (!split[0] && !oc[c]) return 0;
    return 1;
  endfunction
