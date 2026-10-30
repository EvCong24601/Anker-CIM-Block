// Simulation-only checks and reference helpers. Include inside the consuming module.
// Cluster helpers use types and synthesizable helpers already declared in that module.
  function automatic bit canonical(input logic [6:0] s);
    if (!s[0]) return s == 0;
    if (!s[1] && (s[3] || s[4])) return 0;
    if (!s[2] && (s[5] || s[6])) return 0;
    return 1;
  endfunction

  // Convolution enables exactly one aligned 8/4/2-Macro reduction group.
  function automatic bit conv_group_legal(input cluster_ctrl_t cmd);
    int count, first;
    count = wbits(int'(cmd.cim_precision));
    first = -1;
    if (count == 0 || !canonical(cmd.cim_reduce_split_mask)) return 0;
    for (int m = 0; m < 8; m++) if (cmd.cim_macro_en_mask[m] && first < 0) first = m;
    if (first < 0 || first % count != 0 || cmd.cim_macro_en_mask != 8'(((1 << count) - 1) << first)) return 0;
    for (int m = 0; m < 8; m++) begin
      if (cmd.cim_macro_en_mask[m] && first_leaf(cmd.cim_reduce_split_mask, m) != first) return 0;
      if (!cmd.cim_macro_en_mask[m] && first_leaf(cmd.cim_reduce_split_mask, m) == first) return 0;
    end
    return 1;
  endfunction

  function automatic longint signed number(input int unsigned raw, input int bits, input bit sign_en);
    longint signed n;
    n = raw & ((64'd1 << bits) - 1);
    if (sign_en && ((n >> (bits - 1)) & 1)) n -= 64'd1 << bits;
    return n;
  endfunction
